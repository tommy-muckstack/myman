# Contributing to My Man

PRs are welcome. The bar: the app must stay fast, minimal, on-device, and crash-free.

## Getting started

```bash
./scripts/run-dev.sh   # build + launch a dev copy
swift build            # compile check only
```

Before opening a PR, make sure **both** configurations build:

```bash
swift build
swift build -c release --arch arm64 --arch x86_64
```

(The release configuration enforces stricter concurrency checking and has caught errors debug builds tolerate.)

## House rules — please read before writing code

- **Design tokens only.** Colors, fonts, radii, and spacing come from `src/Core/DesignSystem.swift` (`MM.*`). Never hardcode colors or use fonts other than Outfit.
- **Everything clickable gets `.clickable()`** — the ≥24pt hit target + pointing-hand standard. Icon-only buttons without it are effectively unclickable (SVG strokes are the only hit area).
- **Panel doctrine** (this prevented a whole crash class — see `FloatingPanel.swift`):
  - Panels with *static* content use the default `FloatingPanel` (autolayout hosting).
  - Panels whose content *changes size while visible* must pass `fixedSize: true` and size their window explicitly (or estimate, then correct after the window is shown). SwiftUI content must never resize a window through autolayout mid-layout-pass.
- **Never resize a window from inside a layout pass.** GeometryReader size reports arrive during layout; defer any `setFrame` with `DispatchQueue.main.async` and coalesce to the newest size.
- **Entitlements**: any new capability touching protected resources (camera, calendar, etc.) needs its hardened-runtime entitlement in `myman-direct.entitlements`, or notarized builds will silently fail where dev builds work.
- **Audio**: all mic capture goes through the shared `AudioCapture` session API. Never create a second `AVAudioEngine`; never enable voice processing while another app owns the mic.
- **Privacy**: analytics properties are counts, kinds, and durations only — never user content. All AI stays on-device.
- **No blocking the main thread at launch** — model loads and engine warm-ups belong on background queues.
- **Dependencies**: FluidAudio is pinned `exact:` deliberately; do not bump any pin without discussing in an issue first.

## PR process

1. Fork, branch from `main`, keep PRs focused (one change per PR).
2. Describe what you changed and *how you verified it* — for UI work, screenshots or a short recording of the running app.
3. CI must pass (`swift build` on macOS).
4. The maintainer reviews and merges. Releases (signing, notarization, the update feed) are maintainer-only.

## Reporting bugs

Open an issue with your macOS version, app version (Settings shows it at the bottom), and steps to reproduce. Crash reports from `~/Library/Logs/DiagnosticReports/MyMan-*.ips` are gold.
