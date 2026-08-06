#!/bin/bash
set -euo pipefail

# Builds My Man for DIRECT DOWNLOAD (non-App-Store). Cloned from the Mumbls
# pipeline; the two apps SHARE one Vercel Blob store, so every uploaded
# pathname is prefixed "myman" — never touch mumbls.dmg / appcast.xml.
#
# Produces + uploads:
#   myman-$VERSION.dmg  — immutable versioned artifact (cache 1 year)
#   myman.dmg           — stable alias for muckstack.com/download/myman (cache 300s)
#   myman-appcast.xml   — Sparkle feed (cache 300s)
#
# LOCAL MODE (default):
#   Developer ID cert + notary profile "mumbls-notary" from macOS Keychain
#   (same Apple account/team; notary creds aren't app-specific).
#   Sparkle EdDSA key from Keychain account "myman" (NOT Mumbls' default key).
#   Vercel Blob token from .vercel/.env or .env.local.
#   Prereqs: `create-dmg`, `vercel` CLI, notarytool profile.
#
# CI MODE (auto-detected when env vars are present):
#   CERT_P12_BASE64 / CERT_PASSWORD / APPLE_ID / APPLE_TEAM_ID /
#   APPLE_APP_PASSWORD / SPARKLE_ED_PRIVATE_KEY / BLOB_READ_WRITE_TOKEN /
#   RELEASE_VERSION / RELEASE_BUILD
#
# Usage: ./scripts/build-direct.sh [--skip-notarize]

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="My Man"
EXEC_NAME="MyMan"
SLUG="myman"
BUNDLE_ID="com.muckstack.myman"
VERSION="${RELEASE_VERSION:-1.1.32}"
BUILD_NUMBER="${RELEASE_BUILD:-44}"
TEAM_ID="${APPLE_TEAM_ID:-K8NAZ76CBQ}"
NOTARY_PROFILE="mumbls-notary"
SPARKLE_ACCOUNT="myman"
SKIP_NOTARIZE=false

SPARKLE_PUBLIC_KEY="dfceyA2qSn17riGZ9phwSp+bUA3uC67gIGdPqlHoi/A="
BLOB_HOST="https://ihvfw4x5q9iy9zx1.public.blob.vercel-storage.com"
APPCAST_URL="$BLOB_HOST/$SLUG-appcast.xml"

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
    esac
done

# --- CI keychain setup ---------------------------------------------------
CI_KEYCHAIN=""
cleanup() {
    if [[ -n "$CI_KEYCHAIN" ]]; then
        security delete-keychain "$CI_KEYCHAIN" 2>/dev/null || true
    fi
    rm -f "$SCRIPT_DIR/.sparkle_ed_key" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/ci-cert.p12" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n "${CERT_P12_BASE64:-}" ]]; then
    echo "==> CI mode: importing Developer ID certificate into temporary keychain..."
    CI_KEYCHAIN="$SCRIPT_DIR/ci-build.keychain-db"
    KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    P12_PATH="$SCRIPT_DIR/ci-cert.p12"
    echo "$CERT_P12_BASE64" | base64 --decode > "$P12_PATH"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$CI_KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"
    security import "$P12_PATH" -P "${CERT_PASSWORD:-}" \
        -A -t cert -f pkcs12 -k "$CI_KEYCHAIN"
    security list-keychains -d user -s "$CI_KEYCHAIN" $(security list-keychains -d user | tr -d '"')
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$CI_KEYCHAIN"
    rm -f "$P12_PATH"
fi

DEV_ID_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [[ -z "$DEV_ID_IDENTITY" ]]; then
    echo "ERROR: No 'Developer ID Application' certificate found in Keychain."
    exit 1
fi
echo "==> Signing identity: $DEV_ID_IDENTITY"
echo "==> Version: $VERSION (build $BUILD_NUMBER)"

# Local release-only credentials live in this gitignored file. CI supplies
# the same values as environment variables instead.
if [[ -f "$SCRIPT_DIR/secrets.env" ]]; then
    set -a; source "$SCRIPT_DIR/secrets.env"; set +a
fi

echo "==> Building $EXEC_NAME (release, universal)..."
# Universal so Intel Macs can run it; --arch flags move output to .build/apple/.
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/$EXEC_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

# Sentry needs the exact dSYMs produced alongside the universal executable to
# turn crash and app-hang addresses back into Swift symbols. Keep this outside
# the app bundle and never make a customer release depend on diagnostics.
#
# Create a Sentry internal integration token with org:read + project:releases
# (or org:ci) and put it in the gitignored secrets.env as
# MM_SENTRY_AUTH_TOKEN=..., or export SENTRY_AUTH_TOKEN in CI.
upload_sentry_debug_symbols() {
    local token="${SENTRY_AUTH_TOKEN:-${MM_SENTRY_AUTH_TOKEN:-}}"
    local products_dir="$SCRIPT_DIR/.build/apple/Products/Release"
    if [[ -z "$token" ]]; then
        echo "WARNING: MM_SENTRY_AUTH_TOKEN not set — skipping Sentry dSYM upload"
        return 0
    fi
    if ! command -v sentry-cli >/dev/null 2>&1; then
        echo "WARNING: sentry-cli not installed — skipping Sentry dSYM upload"
        return 0
    fi
    if [[ ! -d "$BINARY.dSYM" ]]; then
        echo "WARNING: MyMan.dSYM missing — skipping Sentry dSYM upload"
        return 0
    fi
    echo "==> Uploading release dSYMs to Sentry..."
    # Upload the Products directory, not only MyMan.dSYM: Sparkle's updater
    # helpers can also appear in hang/crash stacks and need their own symbols.
    if ! SENTRY_AUTH_TOKEN="$token" sentry-cli debug-files upload \
        --org muckstack --project myman "$products_dir"; then
        echo "WARNING: Sentry dSYM upload failed — continuing with release"
    fi
}

upload_sentry_debug_symbols

echo "==> Assembling $APP_NAME.app..."
APP_DIR="$SCRIPT_DIR/.build/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/"{MacOS,Frameworks,Resources}

cp "$BINARY" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true

# All dynamic frameworks from SPM artifacts (Sparkle etc.)
echo "==> Bundling dynamic frameworks from SPM artifacts..."
while IFS= read -r slice; do
    for fw in "$slice"/*.framework; do
        [[ -d "$fw" ]] || continue
        echo "    $(basename "$fw")"
        cp -aR "$fw" "$APP_DIR/Contents/Frameworks/"
    done
done < <(find "$SCRIPT_DIR/.build/artifacts" -type d -name "macos-arm64_x86_64" 2>/dev/null)

BUNDLE_DIR=".build/apple/Products/Release/MyMan_MyMan.bundle"
if [[ -d "$BUNDLE_DIR" ]]; then
    cp -R "$BUNDLE_DIR" "$APP_DIR/Contents/Resources/"
fi

cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp scripts/myman "$APP_DIR/Contents/Resources/myman"
chmod +x "$APP_DIR/Contents/Resources/myman"
for chatterbox_helper in chatterbox_server.py install-chatterbox.sh run-chatterbox.sh; do
    cp "scripts/$chatterbox_helper" "$APP_DIR/Contents/Resources/$chatterbox_helper"
done
chmod +x "$APP_DIR/Contents/Resources/install-chatterbox.sh" "$APP_DIR/Contents/Resources/run-chatterbox.sh"

# Info.plist — keep the usage strings in lockstep with scripts/run-dev.sh;
# TCC grants key off the signing identity + these strings.
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>MMChannel</key><string>release</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><false/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.muckstack.myman.command</string>
        <key>CFBundleURLSchemes</key><array><string>myman</string></array>
    </dict></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MuckStack, LLC. All rights reserved.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>My Man records your voice for dictation and your side of meetings.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>My Man records system audio so meeting notes can hear the other participants.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>My Man captures your screen for screenshots.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>My Man watches your calendar to offer meeting notes at the right time.</string>
    <key>NSCameraUsageDescription</key>
    <string>My Man shows your webcam bubble in screen recordings.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>My Man pauses your music while a meeting records.</string>
    <key>SUFeedURL</key><string>$APPCAST_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Telemetry keys: injected into the plist here (never committed to source).
# Local credentials were loaded above; CI provides MM_* environment variables.
# Missing keys are skipped — the app detects their absence and sends nothing.
inject_plist_key() {
    local key="$1" value="$2"
    if [[ -n "$value" ]]; then
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_DIR/Contents/Info.plist"
    else
        echo "WARNING: $key not set — release build will ship without it"
    fi
}
inject_plist_key MMAmplitudeKey "${MM_AMPLITUDE_KEY:-}"
inject_plist_key MMSentryDSN "${MM_SENTRY_DSN:-}"

echo "==> Code signing with Developer ID + hardened runtime..."
# Sparkle.framework: nested helpers from inside out.
SPARKLE_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_DIR" ]]; then
    SPARKLE_VER="$SPARKLE_DIR/Versions/B"
    if [[ -d "$SPARKLE_VER/XPCServices" ]]; then
        for xpc in "$SPARKLE_VER/XPCServices"/*.xpc; do
            [[ -d "$xpc" ]] || continue
            codesign --force --timestamp --options runtime \
                --sign "$DEV_ID_IDENTITY" "$xpc"
        done
    fi
    if [[ -d "$SPARKLE_VER/Updater.app" ]]; then
        codesign --force --timestamp --options runtime \
            --sign "$DEV_ID_IDENTITY" "$SPARKLE_VER/Updater.app"
    fi
    if [[ -f "$SPARKLE_VER/Autoupdate" ]]; then
        codesign --force --timestamp --options runtime \
            --sign "$DEV_ID_IDENTITY" "$SPARKLE_VER/Autoupdate"
    fi
fi

find "$APP_DIR/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" | while read -r fw; do
    codesign --force --timestamp --options runtime \
        --sign "$DEV_ID_IDENTITY" "$fw"
done

codesign --force --deep --timestamp --options runtime \
    --entitlements "$SCRIPT_DIR/myman-direct.entitlements" \
    --sign "$DEV_ID_IDENTITY" "$APP_DIR"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

notarize() {
    local path="$1"
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
        xcrun notarytool submit "$path" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait
    else
        xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait
    fi
}

if $SKIP_NOTARIZE; then
    echo "==> Skipping notarization (--skip-notarize)"
else
    echo "==> Notarizing app (this takes 2-10 minutes)..."
    ZIP_PATH="$SCRIPT_DIR/.build/dist/$SLUG-notarize.zip"
    rm -f "$ZIP_PATH"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    notarize "$ZIP_PATH"
    rm -f "$ZIP_PATH"

    echo "==> Stapling notarization ticket to app..."
    xcrun stapler staple "$APP_DIR"
fi

# Build DMG
DMG_PATH="$SCRIPT_DIR/.build/dist/$SLUG-$VERSION.dmg"
rm -f "$DMG_PATH"
echo "==> Creating DMG..."

if ! command -v create-dmg &> /dev/null; then
    echo "ERROR: create-dmg not found. Install it: brew install create-dmg"
    exit 1
fi

if ! create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 140 180 \
    --app-drop-link 400 180 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG_PATH" "$APP_DIR"
then
    # create-dmg's AppleScript Finder-layout step fails without Automation
    # permission; fall back to plain hdiutil for a valid if plainer DMG.
    echo "==> create-dmg failed; falling back to hdiutil..."
    rm -f "$DMG_PATH"
    STAGE_DIR="$SCRIPT_DIR/.build/dist/.dmg-stage"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -aR "$APP_DIR" "$STAGE_DIR/"
    ln -s /Applications "$STAGE_DIR/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGE_DIR"
fi

if ! $SKIP_NOTARIZE && [[ -f "$DMG_PATH" ]]; then
    echo "==> Signing DMG..."
    codesign --force --timestamp --sign "$DEV_ID_IDENTITY" "$DMG_PATH"
    echo "==> Notarizing DMG (2-10 more minutes)..."
    notarize "$DMG_PATH"
    echo "==> Stapling DMG..."
    xcrun stapler staple "$DMG_PATH"
fi

# Sparkle appcast + Blob upload — every pathname prefixed "$SLUG".
if [[ -f "$DMG_PATH" ]] && ! $SKIP_NOTARIZE; then
    SIGN_UPDATE="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    if [[ ! -x "$SIGN_UPDATE" ]]; then
        echo "ERROR: sign_update not found — run 'swift package resolve'."
        exit 1
    fi

    echo "==> Signing update with EdDSA key (account: $SPARKLE_ACCOUNT)..."
    if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        SPARKLE_KEY_FILE="$SCRIPT_DIR/.sparkle_ed_key"
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
        chmod 600 "$SPARKLE_KEY_FILE"
        SIGN_OUTPUT=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG_PATH")
    else
        SIGN_OUTPUT=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG_PATH")
    fi
    ED_SIG=$(echo "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
    DMG_LEN=$(echo "$SIGN_OUTPUT" | sed -E 's/.*length="([^"]+)".*/\1/')
    PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
    VERSIONED_DMG_NAME="$SLUG-$VERSION.dmg"
    VERSIONED_DMG_URL="$BLOB_HOST/$VERSIONED_DMG_NAME"

    echo "==> Generating $SLUG-appcast.xml..."
    APPCAST_PATH="$SCRIPT_DIR/.build/dist/$SLUG-appcast.xml"
    cat > "$APPCAST_PATH" << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>My Man</title>
        <link>$APPCAST_URL</link>
        <description>Updates for My Man</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
            <enclosure url="$VERSIONED_DMG_URL"
                       sparkle:edSignature="$ED_SIG"
                       length="$DMG_LEN"
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
APPCAST

    if [[ -z "${BLOB_READ_WRITE_TOKEN:-}" && -f ".vercel/.env" ]]; then
        set -a; source .vercel/.env; set +a
    fi
    if [[ -z "${BLOB_READ_WRITE_TOKEN:-}" && -f ".env.local" ]]; then
        set -a; source .env.local; set +a
    fi
    # A pulled VERCEL_OIDC_TOKEN hijacks `vercel blob put`; force the rw token.
    unset VERCEL_OIDC_TOKEN BLOB_STORE_ID

    if [[ -n "${BLOB_READ_WRITE_TOKEN:-}" ]]; then
        echo "==> Uploading to Vercel Blob..."
        vercel blob put "$DMG_PATH" --pathname "$VERSIONED_DMG_NAME" \
            --force true --content-type application/x-apple-diskimage \
            --cache-control-max-age 31536000
        vercel blob put "$DMG_PATH" --pathname "$SLUG.dmg" \
            --force true --content-type application/x-apple-diskimage \
            --cache-control-max-age 300
        vercel blob put "$APPCAST_PATH" --pathname "$SLUG-appcast.xml" \
            --force true --content-type application/rss+xml \
            --cache-control-max-age 300
    else
        echo "==> Skipping upload (no BLOB_READ_WRITE_TOKEN)"
    fi
fi

echo ""
echo "✓ Done."
echo "  App:      $APP_DIR"
echo "  DMG:      $DMG_PATH"
echo "  Latest:   $BLOB_HOST/$SLUG.dmg"
echo "  Version:  $BLOB_HOST/$VERSIONED_DMG_NAME"
echo "  Appcast:  $APPCAST_URL"
