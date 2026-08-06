#!/bin/bash
# Dev runner: build, assemble a minimal MyMan.app (TCC prompts need a real
# bundle with usage strings), ad-hoc sign, launch. The notarized release flow
# lives in build-direct.sh (cloned from Mumbls) when we ship.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="My Man"
BUNDLE_ID="com.muckstack.myman"
BUILD_DIR=".build/debug"
APP_DIR=".build/dev/$APP_NAME.app"

swift build

pkill -f "$APP_NAME.app/Contents/MacOS/MyMan" 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/"{MacOS,Frameworks,Resources}

cp "$BUILD_DIR/MyMan" "$APP_DIR/Contents/MacOS/"
cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp scripts/myman "$APP_DIR/Contents/Resources/myman"
chmod +x "$APP_DIR/Contents/Resources/myman"
[ -d "$BUILD_DIR/MyMan_MyMan.bundle" ] && cp -R "$BUILD_DIR/MyMan_MyMan.bundle" "$APP_DIR/Contents/Resources/"

# ALL dynamic frameworks from SPM artifacts (Sparkle, AmplitudeCore, …) —
# mirror build-direct.sh; a Sparkle-only copy left AmplitudeCore missing and
# the app dead at dyld.
while IFS= read -r slice; do
    for fw in "$slice"/*.framework; do
        [ -d "$fw" ] || continue
        # Plain -R (not -a): ACL preservation flakes on some SPM artifacts,
        # and a dev bundle doesn't need preserved metadata anyway.
        cp -R "$fw" "$APP_DIR/Contents/Frameworks/"
    done
done < <(find .build/artifacts -type d -name "macos-arm64_x86_64" 2>/dev/null)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/MyMan" 2>/dev/null || true

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MyMan</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>MMChannel</key><string>dev</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><false/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.muckstack.myman.command</string>
        <key>CFBundleURLSchemes</key><array><string>myman</string></array>
    </dict></array>
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
    <key>SUFeedURL</key>
    <string>https://ihvfw4x5q9iy9zx1.public.blob.vercel-storage.com/myman-appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>dfceyA2qSn17riGZ9phwSp+bUA3uC67gIGdPqlHoi/A=</string>
</dict>
</plist>
PLIST

# Telemetry keys from gitignored secrets.env (maintainer only). Absent for
# everyone else — dev builds then run with telemetry off, which is fine.
if [[ -f "secrets.env" ]]; then
    set -a; source secrets.env; set +a
    for pair in "MMAmplitudeKey:${MM_AMPLITUDE_KEY:-}" "MMSentryDSN:${MM_SENTRY_DSN:-}"; do
        key="${pair%%:*}"; value="${pair#*:}"
        [ -n "$value" ] && /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_DIR/Contents/Info.plist"
    done
fi

# Sign with the real Developer ID when available — TCC keys permission grants
# to the code signature, and ad-hoc signatures change identity on every
# rebuild, which makes macOS re-prompt for Screen Recording/mic forever.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" | sed 's/.*"\(.*\)"/\1/')
codesign --force --deep --sign "${IDENTITY:--}" "$APP_DIR"
open "$APP_DIR"
echo "Launched $APP_DIR (signed: ${IDENTITY:-ad-hoc})"
