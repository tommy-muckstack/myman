# Agent CLI parity

Working baseline: 1.1.59 (71). The supplied GrokBot feedback inspected an older checkout: the released app already has 45 schema-described actions, a same-login Unix socket, capture/edit/OCR, recording/meeting/dictation sessions, note/task/theme mutations, fonts, and bounded jobs. This work extends those controllers and schemas.

## Implementation plan

1. Add native, default-off capture, markup, recording, and library-mutation consent; keep diagnostics and stop/cancel available. Brain MCP becomes retrieval-only.
2. Add resource/action CLI with JSON output, stable exit codes, input files/stdin, legacy interactive aliases, session-safe controls, and discoverable schemas.
3. Fill native gaps: doctor, append notes, recording cancel/audio options, display-local geometry, window capture, markup validation/colors, source/result metadata.
4. Document every capability, package a Mac-local GrokBot skill, validate manifests and bundled artifacts.
5. Run fixture CLI/MCP and native tests, plus isolated app smoke workflows. Record host-dependent marketplace checks honestly.

The working matrix and verification evidence are completed alongside implementation. Pointer simulation is excluded: structured annotation and capture APIs cover the requested workflows without a remote-control daemon. Hardware gestures, OS permission grants, and marketplace approval remain human/host responsibilities.

## Linux companion

Linux 0.13.0 is a separate Node 22+/X11/Wayland capture and library companion; the Swift app is unchanged. See [installation and contract](linux-agents.md). “Unsupported” below means a structured `unsupported_on_platform` error, including when the corresponding MCP tool is called. Existing Brain export retrieval is portable. `actions` marks platform support independently of owner grants.

## Capability matrix

The macOS first-class rows are implemented. Linux support is intentionally limited to the column below. Generic `invoke` remains available for exact JSON schemas; `myman actions` is authoritative for names and arguments.

| Human capability | Agent equivalent | Linux | Notes |
| --- | --- | --- | --- |
| Launcher / notes / settings panels | bare `open`, `note`, `settings`; `invoke app.open` | Unsupported | Interactive dispatch, no completed-capture claim |
| Interactive screenshot picker | bare `screenshot` | No picker; bare screenshot captures desktop | Human selects region |
| Display / region screenshot | `screenshot --mode agent` | Supported (X11, Hyprland/Omarchy, Sway; scale 1) | JSON completion; global or display-local geometry |
| Window screenshot | `windows list`, `screenshot --window-id` | `windows list` and `screenshot --window-id` on X11, Hyprland/Omarchy and Sway (app, title, PID, workspace, frame, ready `region`) | Real ScreenCaptureKit ID; app/title supplied in discovery |
| Arrow / box / highlight / text / pixelate / crop / image overlay | `annotate --ops-file` | All except image overlay; explicit pixel geometry, or `target_text`/`target_region` resolved by tesseract with the Mac rules (exact word first, then line; 6px padding; ambiguity returns candidates) | Source preserved, new ID, OCR refresh, validation-only dry run |
| One-command capture and markup | `capture-markup` | Supported; capture + markup grants, saves only the marked-up image | Saves only final rendered capture |
| Backdrops / custom colors / rounding | `annotate --background/--background-color/--corner-radius` | Per-operation colors only | Existing renderer; custom color uses user's existing preference |
| Background removal | `capture remove-background` | Unsupported | No-foreground is an explicit failure |
| OCR / regions / copy text | `capture ocr`, `capture copy --text-only` | Tesseract at save; `capture ocr` returns line text with pixel and normalized boxes; no Live Text copy | Individual OCR boxes returned; caller selects text |
| Open capture / save / image bytes / clipboard | `editor open`, `editor save`, `capture image`, `clipboard read/write` | annotate/editor save and capture image; `clipboard read` (text/PNG) and `clipboard write` (text, or a capture as PNG) via xclip or wl-clipboard; no UI | Editor save applies supplied operations to stored image; it does not commit an unrelated open editor's unsaved edits |
| Screen recording start / status / stop / discard | `record start/status/stop/cancel` | Supported, video only (ffmpeg on X11, wf-recorder on Hyprland/Sway) | Session ID required to stop/cancel; native UI remains visible |
| Recording pause / resume | `record pause/resume --session-id` | Supported; each pause closes a segment and stop joins them; bar indicator and notices show the paused state | Paused time is excluded from the video |
| Recording frames | `record frames --id [--times\|--count] [--width]` | Supported (ffmpeg); up to 12 temporary PNGs plus a labeled contact sheet, one-hour expiry | No library writes |
| Recording export and timed edits | `record export --id [--start --end] [--max-bytes] [--edits]` | Supported (ffmpeg); captions, steps, title cards, zoom, redaction with the Mac rules; byte cap lowers resolution, never truncates; leases unsupported | New library recording, source preserved |
| Recording narration toggle / system audio / webcam | `record start --mic/--system-audio/--webcam`, `record microphone --enabled` | Unsupported | Per-start audio/camera settings; existing camera bubble |
| Recording restart / countdown | cancel then explicit start; countdown is UI-only | Unsupported | No autonomous retry or hidden picker |
| Meeting start / title / stop / discard | `meeting start/status/rename/stop/cancel` | Linux: `meeting start/stop/cancel/status` (microphone as You, computer audio as Others; rename via `library rename`) | Records an existing call on this Mac, never auto-joins |
| Meeting transcript / notes / related captures | `meetings`, `read`, `meeting notes`, `library related`, `screenshots --meeting` | Existing exports readable; Linux writes the same `meetings/` format with a local Whisper transcript (`transcript_status` processing, ready, unavailable or failed); notes and summaries Mac-only | Summary generation uses existing service; processing can be pending |
| Meeting auto-detection preference | `meeting config get/set` | Unsupported | Exposes existing auto_record_meetings; no new scheduling behavior |
| Dictation hold / toggle / cancel | `dictation start/status/stop/cancel` | Unsupported (Linux: Voxtype, F9; history via `dictation connect`) | Existing paste/clipboard behavior; result text and saved ID |
| Notes create / append / replace / open | `note create/append/update/open` | Create, append and replace (revision guard); open unsupported | Markdown, title, stdin/file input; replacement revision guard |
| Note bold/lists/tables/link content | Markdown supplied to note create/update | Markdown body preserved | Native visual selection menus are UI chrome |
| Drop images into notes / full-screen image viewing | `note attach --source-id/--path` | Supported; owned PNG copy with alt text (warns when missing) | Document-owned copy and Markdown; full-screen viewing remains the native UI |
| Search / recent captures / related / kinds | `library search/recent/related`, `latest`, `collect` | `library search`: exact phrase, all words, one-typo matches, date/kind/pinned filters; `library related` by links, window, time and title words; no semantic | Search shares native fuzzy/semantic ranking; explicit offline mode retains export keywords |
| Themes by keywords/date/descriptors | `collect` filters, `theme list` | Read existing exports | Saved themes or agent synthesis from cited evidence |
| Pin / rename / hide / delete | `library pin/unpin/rename/hide/unhide/delete` | Supported; revision guard; delete needs `--confirm` and removes owned media | Delete requires confirmation and normal data lifecycle |
| Clear history | `history clear --confirm` | Unsupported | Separate library consent, native deletion pipeline |
| Theme rename / pin / dismiss / merge / membership | `theme rename/pin/unpin/dismiss/merge/add/remove` | Unsupported | Correction controls, never tasks/projects |
| Tasks create / list / title / notes / due / done / delete | `task add/list/update/complete/reopen/delete` | Supported; Mac export format, version guard, delete needs `--confirm` | App DB then export; IDs returned |
| People / vocabulary retrieval | `collect '{"kinds":["people","vocabulary"]}'` | Supported (existing exports) | Read-only; dictation vocabulary editing remains Settings UI |
| Font from screenshot / match / specimen / export / reopen | `font match/create/preview/file/open` | Unsupported | Limited bundled-style matching; glyph correction and installation remain human UI |
| On-image translation | UI-only on macOS 15+ | Unsupported | Current Apple translation session is supplied by SwiftUI and may need a language-download consent sheet; no headless claim |
| Privacy/search settings | `settings get/set` | Unsupported | Allowlisted automatic_themes, semantic_search, window_metadata, excluded_apps |
| Agent consent / TCC grants | Human-only Settings | Owner-only config plus optional root ceiling; all user grants default off | Cannot be enabled through CLI, URL or MCP |
| Named agent credentials | Human-only Settings (Mac); `myman agents add/revoke/require` at an interactive terminal (Linux) | Supported; `MYMAN_AGENT_TOKEN`, scopes only narrow grants and the root ceiling; refused without a TTY or inside an agent | Credentials tell cooperating agents apart; not a same-login sandbox |
| Identity / directory / machine | `agent whoami`, `agent list`, `machine current`, `--machine` | Supported; `WRONG_MACHINE` when the machine ID differs | Machine ID is local; remote execution is up to the host |
| Bundles / handoffs / events | `bundle create/list/read/update/delete`, `handoff create/list/read/update`, `collaboration events` | Supported (library grant, named agents); references plus revisions, never copies; Mac transitions and limits | No agent is launched or messaged |
| Leases / recording ownership | `lease acquire/release`, `--lease-id` on mutations, `session transfer` | Supported; clipboard and `item:ID` leases; recordings owned by their starter | Leases are cooperative; revision checks still apply |
| Hotkey rebinding / audio model selection / destination folder / update preferences | Human-only Settings | No UI; Brain and XDG paths via environment | Machine setup; no unrestricted preference editor |
| Permissions / setup | `doctor` | Supported; passive doctor | Passive, no OS prompts |
| Calendar agenda | `calendar list --after ISO --before ISO` | Unsupported | Existing Calendar permission; bounded 31-day read |
| Quick tools / calculator / time zones / palettes | `tool evaluate --input TEXT` | Unsupported | Structured local results; no side effects |
| Reminders | `reminder create/list/cancel/sound` | Supported (library grant); `seconds` or ISO `at` with offset; overdue reminders are delivered at the next MyMan call | Saved reminders and notifications |
| Timers | `timer start/status/pause/resume/cancel/sound` | Supported (library grant); desktop notice and optional sound when done, no on-screen widget; systemd user timer or detached waiter | Visible widget, session IDs, creating-agent controls |
| Chat beta / Chatterbox voice replies | Optional future phase | Unsupported | Not required for capture/recall CLI parity |
| Pointer / click / drag / arbitrary keyboard injection | Excluded | Excluded | Structured capture/markup replaces pointer automation; no remote-control daemon |
| Sparkle installation / TCC / Font Book | Human/app-only | Unsupported | Native installation and OS consent surfaces |
| Remote meeting participant / cloud Brain hosting / automatic messages | Out of scope | Out of scope | No such product behavior is introduced |

## Verification

See [next-version evidence](verification/agent-cli-2026-09-12.md). Tests distinguish parser/schema coverage, real native fixture actions, and host-dependent marketplace verification. A successful local MCP test is not evidence that GrokBot loaded a plugin.

## Media workflows added for 1.1.61

| Capability | CLI | Linux | Behavior |
| --- | --- | --- | --- |
| OCR targets | `capture targets --query` | Supported (tesseract; line and word granularity, stable IDs) | Stable line IDs, pixel rectangles, explicit ambiguity |
| Screenshot comparison | `capture compare --before-id --after-id` | Supported (ImageMagick + tesseract; same fields, 32px regions, one-hour side-by-side PNG) | Changed pixels and ratio, regions, added/removed OCR text |
| Import an image | `capture import --path` | Supported; PNG, JPEG, WebP or GIF detected by content (64 MB cap), normalized to PNG | New capture item with OCR |
| Rendered markup preview | `annotate --preview` | Supported; one-hour local preview | Temporary PNG; no library/clipboard/preference changes |
| Theme-matched markup colors | App accent/markup colors | Supported on Omarchy (active theme colors.toml; `MYMAN_MARKUP_THEME=none|FILE`) | Explicit op colors always win |
| Circles and numbered callouts | `annotate --ops` | Unsupported | Text/region targets or explicit geometry; existing editor renderer |
| Window video | `record start --window-id` | Unsupported | Selected window only; region/webcam conflicts rejected |
| Bounded video | `record start --max-duration` | Unsupported | App-owned deadline survives client disconnect; default 300 seconds |
| Pause/resume | `record pause/resume --session-id` | Unsupported | One session; paused time excluded through segment assembly |
| Completed session retrieval | `record result --session-id` | Unsupported | Finalized file and attachment, including after automatic stop |
| Frame/contact-sheet inspection | `record frames --times/--count` | Unsupported | Bounded temporary PNG previews with actual timestamps |
| Trim/MP4/size cap | `record export --start/--end/--max-bytes` | Unsupported | New library item, source preserved; no truncation to meet size |
| Attachment metadata | Capture/edit/record/export results | Supported for capture/edit/preview | Path, MIME, dimensions, duration, bytes and preview |
| Person shows agents a region | `show --note` (person only), Omarchy `SUPER+SHIFT+PRINT` via `omarchy install` | Unsupported | Saved as a `shown` library capture with the note; agents cannot trigger it |
| Dictation history | `dictation connect` (person only) saves each Voxtype dictation; read with `library search --kind dictations` | Dictation start/stop and paste are Voxtype's (F9) | Same `dictations/` export format as the Mac |
| Meetings | `meeting start [--title] [--no-system-audio] [--keep-audio]`, `meeting stop`, `meeting cancel`, `meeting status`; read with `library search --kind meetings` | Live notes, the meeting assistant and auto-detection are Mac-only | Same `meetings/` export format as the Mac; agents need the recording and microphone grants |
| Recording cursor track | `record cursor --id REC-ID [--full]` (pointer, clicks, typing moments, activity spans) | Hyprland: movement only; Sway: unavailable | Saved beside each recording; keys are never identified |
| Polished demo: smooth auto-zoom | `record polish --id REC-ID --auto-zoom [level] [--recipe JSON] [--dry-run]` | Linux and Mac. Mac zooms on the recorded clicks or hand-written moments with the recording editor's engine; per-moment levels, `ramp` and `gap` are Linux only | New recording; same recipe and names on both |
| Polished demo: cursor polish | `record start --hide-cursor`; `record polish --id REC-ID --cursor [normal\|big\|huge\|1-3]` | Linux (X11) and Mac. The Mac draws its smooth cursor from the saved cursor track; highlight and click-ripple colours are Linux only | Drawn smooth arrow when the cursor was hidden |
| Polished demo: background | `record polish --id REC-ID --background dusk\|ocean\|meadow\|slate\|none [--background-color HEX] [--corner-radius N]` | Linux and Mac, the same backdrops, padding and shadow as the image editor (shadow strength is Linux only) | Rounded card on a gradient or colour; output grows by the padding |
| Polished demo: music | `record polish --id REC-ID --music upbeat\|calm\|cinematic\|/path [--music-volume 0-1]` | Linux and Mac, the same CC0 built-in tracks (the `myman` command composes them and hands the Mac app a file) or your own audio file; looped and faded on both. Linux ducks under narration; the Mac plays the music at a lower level under recording audio | Recording audio is kept on both |
| Polished demo: title and end cards | `record polish --title TEXT --end TEXT` or recipe `title` / `end` | Linux and Mac, the same text limits, seconds and fades | Full-frame card on the video's backdrop; music spans the cards |
| One-command demo | `demo --script steps.json [--app CMD] [--dry-run]` | Mac and Linux X11, with the same steps file. The Mac opens the app by name, hides every other app while it records (`focus`, default on) and needs the control grant plus Accessibility; keys use Mac names such as `cmd+s` | Opens the app, records the window, runs click/type/key/scroll steps, zooms where it acted, then polishes; Wayland is unsupported for now |

Verification: [media workflow evidence](verification/agent-media-2026-09-12.md).

## Workflow completion in 1.1.62

Live discovery reports installed app support; bundled fallback is marked unverified. Agents can attach screenshot copies to notes, use native search, inspect font match evidence/specimens and recover bounded durable job/session receipts after restart. The skills include [complete recipes](agent-workflows.md). Privacy grants remain user-controlled; recovery never replays interrupted actions.
