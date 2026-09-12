# Agent CLI parity

Working baseline: 1.1.59 (71). The supplied Hugo feedback inspected an older checkout: the released app already has 45 schema-described actions, a same-login Unix socket, capture/edit/OCR, recording/meeting/dictation sessions, note/task/theme mutations, fonts, and bounded jobs. This work extends those controllers and schemas.

## Implementation plan

1. Add native, default-off capture, markup, recording, and library-mutation consent; keep diagnostics and stop/cancel available. Brain MCP becomes retrieval-only.
2. Add resource/action CLI with JSON output, stable exit codes, input files/stdin, legacy interactive aliases, session-safe controls, and discoverable schemas.
3. Fill native gaps: doctor, append notes, recording cancel/audio options, display-local geometry, window capture, markup validation/colors, source/result metadata.
4. Document every capability, package a Mac-local GrokBot skill, validate manifests and bundled artifacts.
5. Run fixture CLI/MCP and native tests, plus isolated app smoke workflows. Record host-dependent marketplace checks honestly.

The working matrix and verification evidence are completed alongside implementation. Pointer simulation is excluded: structured annotation and capture APIs cover the requested workflows without a remote-control daemon. Hardware gestures, OS permission grants, and marketplace approval remain human/host responsibilities.

## Capability matrix

All first-class rows are implemented. Generic `invoke` remains available for exact JSON schemas; `myman actions` is authoritative for names and arguments.

| Human capability | Agent equivalent | Notes |
| --- | --- | --- |
| Launcher / notes / settings panels | bare `open`, `note`, `settings`; `invoke app.open` | Interactive dispatch, no completed-capture claim |
| Interactive screenshot picker | bare `screenshot` | Human selects region |
| Display / region screenshot | `screenshot --mode agent` | JSON completion; global or display-local geometry |
| Window screenshot | `windows list`, `screenshot --window-id` | Real ScreenCaptureKit ID; app/title supplied in discovery |
| Arrow / box / highlight / text / pixelate / crop / image overlay | `annotate --ops-file` | Source preserved, new ID, OCR refresh, validation-only dry run |
| One-command capture and markup | `capture-markup` | Saves only final rendered capture |
| Backdrops / custom colors / rounding | `annotate --background/--background-color/--corner-radius` | Existing renderer; custom color uses user's existing preference |
| Background removal | `capture remove-background` | No-foreground is an explicit failure |
| OCR / regions / copy text | `capture ocr`, `capture copy --text-only` | Individual OCR boxes returned; caller selects text |
| Open capture / save / image bytes / clipboard | `editor open`, `editor save`, `capture image`, `clipboard read/write` | Editor save applies supplied operations to stored image; it does not commit an unrelated open editor's unsaved edits |
| Screen recording start / status / stop / discard | `record start/status/stop/cancel` | Session ID required to stop/cancel; native UI remains visible |
| Recording narration toggle / system audio / webcam | `record start --mic/--system-audio/--webcam`, `record microphone --enabled` | Per-start audio/camera settings; existing camera bubble |
| Recording restart / countdown | cancel then explicit start; countdown is UI-only | No autonomous retry or hidden picker |
| Meeting start / title / stop / discard | `meeting start/status/rename/stop/cancel` | Records an existing call on this Mac, never auto-joins |
| Meeting transcript / notes / related captures | `meetings`, `read`, `meeting notes`, `library related`, `screenshots --meeting` | Summary generation uses existing service; processing can be pending |
| Meeting auto-detection preference | `meeting config get/set` | Exposes existing auto_record_meetings; no new scheduling behavior |
| Dictation hold / toggle / cancel | `dictation start/status/stop/cancel` | Existing paste/clipboard behavior; result text and saved ID |
| Notes create / append / replace / open | `note create/append/update/open` | Markdown, title, stdin/file input; replacement revision guard |
| Note bold/lists/tables/link content | Markdown supplied to note create/update | Native visual selection menus are UI chrome |
| Drop images into notes / full-screen image viewing | UI-only for asset import | Phase 2: app-owned document asset import; do not write Brain assets manually |
| Search / recent captures / related / kinds | `library search/recent/related`, `latest`, `collect` | Export lexical matching; native semantic ranking is not exposed yet |
| Themes by keywords/date/descriptors | `collect` filters, `theme list` | Saved themes or agent synthesis from cited evidence |
| Pin / rename / hide / delete | `library pin/unpin/rename/hide/unhide/delete` | Delete requires confirmation and normal data lifecycle |
| Clear history | `history clear --confirm` | Separate library consent, native deletion pipeline |
| Theme rename / pin / dismiss / merge / membership | `theme rename/pin/unpin/dismiss/merge/add/remove` | Correction controls, never tasks/projects |
| Tasks create / list / title / notes / due / done / delete | `task add/list/update/complete/reopen/delete` | App DB then export; IDs returned |
| People / vocabulary retrieval | `collect '{"kinds":["people","vocabulary"]}'` | Read-only; dictation vocabulary editing remains Settings UI |
| Font from screenshot / export / reopen | `font create/file/open` | Glyph correction and font installation remain human UI |
| On-image translation | UI-only on macOS 15+ | Current Apple translation session is supplied by SwiftUI and may need a language-download consent sheet; no headless claim |
| Privacy/search settings | `settings get/set` | Allowlisted automatic_themes, semantic_search, window_metadata, excluded_apps |
| Agent consent / TCC grants | Human-only Settings | Cannot be enabled through CLI, URL or MCP |
| Hotkey rebinding / audio model selection / destination folder / update preferences | Human-only Settings | Machine setup; no unrestricted preference editor |
| Permissions / setup | `doctor` | Passive, no OS prompts |
| Fancy visual browsing / calendar grid | UI-only | Data retrieval and config commands cover agent workflows; calendar browsing CLI is phase 2 |
| Chat beta / Chatterbox voice replies | Optional future phase | Not required for capture/recall CLI parity |
| Pointer / click / drag / arbitrary keyboard injection | Excluded | Structured capture/markup replaces pointer automation; no remote-control daemon |
| Sparkle installation / TCC / Font Book | Human/app-only | Native installation and OS consent surfaces |
| Remote meeting participant / cloud Brain hosting / automatic messages | Out of scope | No such product behavior is introduced |

## Verification

See [next-version evidence](verification/agent-cli-2026-09-12.md). Tests distinguish parser/schema coverage, real native fixture actions, and host-dependent marketplace verification. A successful local MCP test is not evidence that GrokBot loaded a plugin.
