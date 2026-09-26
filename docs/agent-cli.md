# MyMan CLI for agents

MyMan 1.1.62 adds live capability discovery, native fuzzy/semantic search, note image attachments, structured font matching/specimens, and restart recovery. It extends 1.1.61's markup/video tools. `myman actions` queries the running app and returns its version, schemas and grants; when unavailable it explicitly labels bundled fallback schemas `live: false`. Use `actions --offline` for documentation only. `invoke` checks live support before executing. See [complete workflow recipes](agent-workflows.md).

## Installation and discovery

Install the signed MyMan app and open it once. Install Node.js 22+ on that Mac. No npm install is needed for the bundled helper:

```sh
"/Applications/My Man.app/Contents/Resources/myman" --help
"/Applications/My Man.app/Contents/Resources/myman" doctor --json
```

Optionally link the helper into your PATH (choose another name if that path already exists):

```sh
mkdir -p ~/.local/bin
ln -s "/Applications/My Man.app/Contents/Resources/myman" ~/.local/bin/myman
```

A relocated app or a symlink works: the helper resolves its own location and loads its bundled companion. The exported fallback is `node "$HOME/MyManBrain/tools/cli.mjs"`. Source development uses `npm ci --ignore-scripts --prefix integrations/brain`. Rebuild committed bundles with `npm run bundle --prefix integrations/brain`.

`--root` selects a Brain export for retrieval only. It never redirects mutations to that folder or to another Mac. App commands require a running MyMan instance under the same login. `doctor` checks app connectivity, OS permissions, enabled agent groups, Node, and export availability without requesting permission. Its individual permission fields describe readiness for each workflow; not every workflow needs every permission.

Linux agents: the separate [Linux companion](linux-agents.md) supports X11 and Hyprland/Omarchy/Sway screenshots, explicit-pixel annotations, notes, and Brain keyword queries. It uses the same capture/library JSON schemas with owner-controlled config grants; Mac-only actions return `unsupported_on_platform`. The following native UI/session/TCC details describe macOS.

## Consent and permissions

Settings → Agents has **Allow local app commands**, plus four separate, default-off grants:

| Setting | Group | Actions |
| --- | --- | --- |
| Capture screenshots without the picker | capture | screenshot capture, shareable window list |
| Edit screenshots and create fonts | markup | import/edit images, remove background, create font |
| Control meetings, dictation and screen recordings | recording | start/control recordings, generate meeting notes, meeting auto-record preference |
| Create and change notes, tasks and library items | library | note/task/theme/library mutations, clipboard writes, safe settings changes |

Combined capture/markup requires both grants. The native bridge checks grants; neither JSON nor URL arguments can enable them. App settings mutation schemas exclude these grant keys. A menu-bar dot indicates that agent screenshot or recording access is enabled. Normal recording controls remain visible. No permanent “silent forever” grant is enabled by default; grants apply to this Mac login until the human turns them off. Session tokens are not implemented. Same-login processes are the trust boundary, not individual agents.

Stop/cancel and screen-recording pause commands remain available after revocation and still require the current session ID. Diagnostics remain available when commands are disabled. Delete (`item.delete`, `task.delete`, `history.clear`) requires library consent **and** `--confirm`. Changing a grant does not undo previously completed actions. Exported files remain readable independently of action settings.

| macOS permission | Needed for |
| --- | --- |
| Screen Recording / Screen & System Audio Recording | screenshots, shareable windows, screen video, meeting system audio |
| Microphone | dictation, meeting microphone, video `--mic on` |
| Camera | video `--webcam on` |
| Accessibility | existing dictation auto-paste and optional browser-window metadata |
| Full Calendar Access | existing calendar view and scheduling behavior |
| Input Monitoring | not required by the CLI; no pointer/key injection is provided |

macOS prompts remain real. A refusal returns `PERMISSION_REQUIRED` with the relevant permission; grant it in System Settings. The CLI never changes TCC settings. The `myman-brain` MCP remains read-only; `myman-app` exposes the CLI’s app actions through the same native permission checks. CLI operations are local; requesting agents may send returned excerpts or pixels to their model provider. MyMan does not automatically upload the Brain or send attachments/messages.

## Capture, annotate, and return an image

```sh
myman screens list --json
myman screenshot --mode agent --display main --region 0,0,1200,800 --wait --json
myman annotate --id shot-RETURNED-ID --ops-file ops.json --dry-run --json
myman annotate --id shot-RETURNED-ID --ops-file ops.json --save --clipboard --json
myman capture ocr --id shot-EDITED-ID --json
myman capture copy --id shot-EDITED-ID --image --json
```

`ops.json`:

```json
[
  {"op":"arrow","from":[30,40],"to":[300,180],"color":"#FF3B30"},
  {"op":"box","rect":[80,100,400,220],"color":"#007AFF"},
  {"op":"highlight","rect":[100,130,200,32]},
  {"op":"text","at":[100,80],"text":"Review this","color":"#FFFFFF","font_size":28},
  {"op":"pixelate","rect":[500,120,180,100]},
  {"op":"crop","rect":[0,0,1000,700]}
]
```

Annotation coordinates are **original image pixels, top-left origin**. `crop` is applied last; all operations refer to the original image. Rectangles must lie inside it. Input is bounded to 1 MiB and 100 annotations. Image overlay operations use `op: image`, an absolute `path`, and `rect`. `--background ocean|dusk|meadow|slate|none`, `--background-color '#112233'`, and `--corner-radius 18` use the existing editor renderer. Colors/fonts can vary per operation. `--dry-run` validates geometry and image inputs without saving, copying, or opening an editor. Editing exports a **new capture** and preserves the source; no destructive replacement is implied by `--save`. OCR/index enrichment runs asynchronously on the resulting pixels.

`capture-markup --mode agent ... --ops-file ops.json` captures and renders through the same code, saving only the final image. `--open-editor` opens the saved result; `--save-only` is the default. Use `capture image --id ...` only to explicitly retrieve base64 PNG pixels; otherwise the absolute `path` is enough for the agent's attachment mechanism.

Display selectors: `main` is the first/main display; `0`, `1`, etc. are screen-list indices, and larger IDs match the returned display ID. Prefer the returned `selector` (for example `id:1`) when selecting by ID; it avoids collisions with numeric indices. With `--display`, `--region` is **display-local points, top-left origin**. Without it, region coordinates are **AppKit global points, bottom-left origin**. `--coordinates global|display-local` is explicit. Regions must fit one display. Captures report the actual composite scale; do not assume every display is @2x.

```sh
myman windows list --json
myman screenshot --mode agent --window-id RETURNED-ID --json
```

Window IDs select ScreenCaptureKit windows directly, including occluded content supported by the OS. Discover app/title in the window list; do not guess an ID or treat a title match as unique. Window capture cannot combine display/region arguments.

Successful capture shape (dimensions and paths vary):

```json
{"ok":true,"id":"shot-UUID","kind":"screenshot","path":"/absolute/capture.png","image_path":"/absolute/capture.png","brain_path":"screenshots/date-id.md","width":2400,"height":1600,"scale":2,"created_at":"ISO8601","timezone":"America/New_York","ocr_status":"processing","job_id":"UUID","launch_id":"UUID"}
```

The file and ID are ready when returned. `brain_path` is the intended source-relative export path; OCR/export publication may still be pending. Poll retrieval instead of pretending the Brain snapshot is already updated.

## Select text and preview markup

```sh
myman capture targets --id shot-ID --query "Save" --json
myman annotate --id shot-ID --ops '[{"op":"circle","target_text":"$49","color":"#FF3B30"}]' --preview --json
myman annotate --id shot-ID --ops '[{"op":"callout","target_region":"ocr-RETURNED-ID","number":1,"text":"Review pricing"}]' --preview --json
```

`capture targets` returns OCR **line** rectangles in original image pixels (top-left), stable IDs, and a total. Queries are case-insensitive substring matches, not semantic descriptions. `target_text` or `target_region` replaces `rect` (or an arrow's `to`). A targeted arrow can omit `from` for automatic placement. Several matches produce `AMBIGUOUS_TARGET` with candidates; no edit is saved. Select a returned region ID to resolve the ambiguity. Missing/stale targets produce `TARGET_NOT_FOUND`. Recheck targets if the underlying image changes. The result is line-level; it does not claim character-accurate word boxes or arbitrary UI element recognition.

`circle` draws an ellipse; `callout` draws a target box and numbered label. Labels use a nearby in-bounds position with minimal overlap with prior labels; preview busy images before committing. Explicit pixel rectangles remain supported. `preview` renders the full output to a temporary PNG; `dry-run` only validates. Neither writes a library item, changes backdrop preferences, or alters the clipboard. They cannot be combined or used with clipboard/open-editor flags. To save, repeat the same operation against the same source ID without `--preview`.

Temporary previews, thumbnails, contact sheets and frames expire after one hour, on app restart, or when an item is deleted/hidden. The cache is capped at 256 files. Treat their paths as short-lived and regenerate them when needed. Saved captures remain in the normal library. `screenshot.ocr` retains the legacy `box` (Vision normalized/bottom-left) and additionally returns the same `id` and pixel `rect` as `capture targets`.

## Recordings, meetings, and dictation

```sh
myman record start --display main --region 0,0,1200,800 --mic off --system-audio on --webcam off --json
myman record status --json
myman record stop --session-id RETURNED-SESSION-ID --json
# Or discard without a movie export:
myman record cancel --session-id RETURNED-SESSION-ID --json

myman meeting start --title "Design review" --json
myman meeting status --json
myman meeting rename --session-id RETURNED-SESSION-ID --title "Follow-up" --json
myman meeting stop --session-id RETURNED-SESSION-ID --json
myman meeting notes --id meeting-RETURNED-ID --json

myman dictation start --json
myman dictation stop --session-id RETURNED-SESSION-ID --json
myman meeting config get --json
myman meeting config set --auto-record-meetings off --json
```

Retain the start result's session ID. Stop/cancel never silently picks another recording. Repeating stop with a retained finalized session ID returns that same saved item. There is no separate Zoom participant: MyMan records a call already running on this Mac. Meetings stop into processing, then Brain retrieval supplies the transcript/summary as it becomes available. Screen recordings require macOS 15+, return a `.mov` path/duration and `transcript_status: pending`; microphone defaults off, system audio on, webcam off. Webcam means the existing floating camera bubble. Cancel discards instead of restarting the picker. Dictation retains its existing paste/clipboard behavior and returns text plus its saved dictation ID when available.

Legacy bare `meeting`, `dictation`, and `record` retain their existing UI toggles. Bare `screenshot` opens the normal picker. They return `interactive: true, dispatched: ...`; they do not claim a completed capture. `--wait` completion and structured geometry belong to agent commands.

## Window recording, pause, inspection and export

```sh
myman windows list --json
myman record start --window-id RETURNED-ID --max-duration 30 --mic off --system-audio off --json
myman record pause --session-id RETURNED-SESSION-ID --json
myman record resume --session-id RETURNED-SESSION-ID --json
myman record status --session-id RETURNED-SESSION-ID --json
myman record stop --session-id RETURNED-SESSION-ID --json
# After an automatic stop or a disconnected client:
myman record result --session-id RETURNED-SESSION-ID --json

myman record frames --id recording-ID --times 0.5,2,5 --width 400 --json
myman record frames --id recording-ID --count 6 --json
myman record export --id recording-ID --start 1 --end 8 --max-bytes 20000000 --json
```

Window capture uses a ScreenCaptureKit window filter. It cannot be combined with display/region/coordinates or a webcam bubble: a floating camera window is not part of the selected window. Full display and region recording retain their existing camera support. Window ID can become invalid if its app closes/replaces the window; discover it again instead of substituting the full display.

Agent recordings default to a **300-second wall-clock limit**, including pauses; `--max-duration` accepts 1–3600 seconds. MyMan owns the timer, so the limit remains active if the agent disconnects. Normal human recordings retain their existing behavior. The stream acknowledges recording output before start succeeds; stop waits for output finalization, narration merge and library insertion. Timing can exceed the requested limit slightly due to capture/encoding shutdown latency.

Named status/result returns `recording`, `pausing`, `paused`, `starting`, `finalizing`, `finalized`, `cancelled`, or `failed`. Pause/resume keeps one session ID and joins completed segments without paused time. `record result` is a poll, not a blocking wait; poll until `finalized` before attaching the file. Up to 32 session receipts persist for seven days across restarts. A session interrupted by restart is labeled `interrupted`, not finalized. Deleting/hiding content clears retained session results; inspect saved library items instead of starting a replacement take. A failed finalization includes `recovery_paths` when partial media survives, and is never labeled finalized.

Frames accepts up to 12 timestamps in seconds, strictly before the file's end, or `--count` for evenly spaced samples. It returns each requested/actual timestamp and PNG metadata, plus a labeled contact sheet. Width defaults to 400 pixels (160–1280); frame aspect ratio is preserved. Inspect these images using the agent host's image viewer.

Export preserves the source and creates a new library recording with a `.mp4` attachment. Bounds are seconds inside the original video. With a size cap, it tries full quality, then 720p and 480p; output dimensions disclose the resulting resolution. If the complete clip still cannot fit, `SIZE_LIMIT_EXCEEDED` returns no truncated video. Increase the cap or shorten the range. A trimmed export has no generated transcript; use the original recording's evidence for analysis.

Saved screenshots, finalized recordings and MP4 exports include an `attachment` object: `path`, `mime_type`, `width`, `height`, `duration` (null for an image), `file_size`, and `preview_path`. Preview generation is best-effort and does not prevent returning a successfully saved original; check for null/unavailable previews. `preview_expires_at` identifies temporary thumbnails. Attach the final file through the requesting host, not a MyMan upload endpoint.

## Notes, library, tasks, themes, and fonts

```sh
myman note create --title "Follow-ups" --body-file - --json < body.md
myman note append --id note-ID --body "Another point" --json
myman note update --id note-ID --body-file body.md --expected-updated-at ISO8601 --json
myman library search --query "Jordan" --kind meetings --json
myman library recent --kind screenshots --limit 20 --json
myman latest --kind screenshots --json
myman library read --id shot-ID --json
myman library related --id shot-ID --json
myman library pin --id shot-ID --json
myman library rename --id shot-ID --title "Pricing page" --json
myman library hide --id shot-ID --json
myman library delete --id shot-ID --confirm --json
myman theme list --json
myman theme rename --id THEME-ID --title "Payments design" --json
myman theme merge --id THEME-ID --target-id OTHER-THEME-ID --json
myman theme add --id THEME-ID --item-id shot-ID --json
myman theme remove --id THEME-ID --item-id shot-ID --json
myman task list --state open --json
myman task add --title "Review design" --notes "Compare variants" --json
myman task complete --id TASK-ID --json
myman task reopen --id TASK-ID --json
myman font match --id shot-ID --json
myman font create --id shot-ID --name "Captured lettering" --json
myman font preview --id note-FONT-ID --text "Hello 0123" --json
myman font file --id note-FONT-ID --json
myman note attach --id note-ID --source-id shot-ID --alt "Design example" --json
myman settings get --json
myman settings set --key automatic_themes --value false --json
```

Append is atomic and preserves a custom title; `--expected-updated-at` optionally rejects intervening changes. Replacement requires the timestamp from `library read`. Rich content is Markdown. Every mutation goes through app models and normal export/deletion lifecycle; never edit exported Markdown as a way to mutate the app. Font creation is the existing screenshot font workbench; missing glyphs may be inferred, not recovered exactly.

Library search uses the native index and the UI’s exact/fuzzy/semantic ranking, with excerpts, match reasons and filters. Use `--lexical-only` for the first pass, or `--offline` for explicit export-keyword fallback. Library recent and theme/task lists continue using the read-only export snapshot and citation/pagination contract. `collect` retains all existing time/participant/theme/descriptor filters. `myman actions` lists the remaining first-class native actions.

## Results, jobs, and errors

With `--json`, stdout contains one JSON object, including errors. Logs belong on stderr. New resource/action results flatten `job.result` and include `job_id`/`launch_id`. Low-level `invoke` and `job` preserve the original job envelope for compatibility. Read tools preserve their citation/pagination envelope. `--no-wait` returns a pending job; `--wait-timeout SECONDS` bounds waiting (default 300, max 600). Timeout does not cancel work. Poll `myman job UUID` after timeout/disconnect; never blindly repeat a mutation. `--request-id UUID` deduplicates across restarts while its receipt is retained. `jobs` lists recent receipts; an interrupted receipt must not be replayed automatically. Completed start receipts do not prove a recording finalized; use its session result.

Exit codes: 0 success or intentionally pending; 2 OS permission missing; 3 cancelled; 4 agent access disabled; 5 invalid arguments/confirmation/conflicting revision or session; 6 operation/setup failure; 7 timeout. Error example: `{"ok":false,"error":{"code":"AGENT_DISABLED","message":"Enable capture access in My Man Settings → Agents for this action."}}`.

The local socket is owned by the login, directory mode 0700, socket mode 0600, peer-UID checked. Payloads, concurrent jobs, retained results, and socket read times are bounded. Receipts live outside Brain in owner-only Application Support for up to seven days, capped at 256 terminal jobs and 32 recording sessions. Inline results above 64 KiB are omitted with artifact references where available. Interrupted jobs are marked on restart, temporary previews expire, and deletion/exclusion redacts retained content. Disk-write failures are reported; no action begins if its start receipt cannot be saved. `MYMAN_AGENT_SOCKET` supports an explicitly chosen owned socket for isolated developer verification, never remote TCP. Tests use a debug-only fixture app and a separate socket.

## Companion 0.7.0: media and readiness

Requires a MyMan build advertising these actions; public 1.1.64 does not contain them. Run live discovery first.

- `capture compare --before-id ID --after-id ID --ignore-rects '[[0,0,120,30]]'`: equal-size images, pixel threshold 20 by default (0–255), source-image top-left coordinates. The temporary side-by-side image highlights changed 32-pixel tiles; JSON includes exact changed pixel counts, a ratio excluding ignored pixels, and added/removed OCR lines. Regions are bounded to 200 with `truncated`; OCR text is heuristic, not proof of functional correctness. Ignoring a region masks it for comparison, not secure redaction.
- `capture targets --id ID --granularity word`: Vision word boxes and stable `word-ocr-...` IDs. `target_text` prefers exact words, preserving ambiguity errors for duplicates, then falls back to line matches for phrases. `target_region` accepts line or word IDs. Existing line IDs and the default line output are unchanged.
- `record export --id ID --edits JSON`: up to 20 timed edits. Each has `type`, `start`, `end`. Caption/title need `text`; step also needs `number` (1–99); zoom/redact need `rect`. Times use the original video, even with trimming. Rectangles use oriented original pixels, top-left. Titles cover existing frames rather than adding duration. Zoom uses a fixed region with letterboxing, limited to 8×. Redaction is opaque and runs before zoom. It covers only the specified visual regions and times; it does not remove spoken audio. Same-type text overlays and zooms cannot overlap. Exports preserve originals; inspect the exported frames before sharing.
- `wait --id ID --stage file|ocr|indexed|transcript|notes|export --timeout 120`: waits for an existing result without scheduling it. `ocr` recognizes a completed empty OCR result. `indexed` checks enrichment for the current item; it does not imply OCR, transcript or export readiness. `export` requires the current revision in the Brain catalog and its document. `transcript`/`notes` wait for available text; silence or processing failure may time out. Timeout is an error with last observed readiness.
- `wait --job-id UUID` or `wait --session-id ID`: follows the existing job or recording to completion. Failures/interruption never restart work. Use `job` to inspect a waiter itself. `--wait-timeout` controls CLI waiting for its native job; `--timeout` controls the requested readiness wait.
- `font quality --id NOTE-ID --text "Intended text"`: actual-font specimen plus per-letter evidence (`supported`, `weak_sample`, `approximate`, `missing`), best sample size, OCR confidence, and suggested letters to capture. These are heuristics, not certainty of identity or fidelity. Quality is also included in `font file` and `font preview`.

## Local app MCP

The root plugin config starts two stdio servers: existing `myman-brain` and new `myman-app`. Manual configuration may start `node /absolute/path/MyManBrain/tools/app-server.mjs`. Each advertised action becomes `myman_app_` plus its dotted name converted to underscores, with a strict schema generated from the shared catalog. `myman_app_capabilities` checks live support and grants; bundled tool availability alone is not proof the running app supports it.

`_request_id` is an optional UUID for deduplication; retain it for mutations. `_wait_timeout` defaults to 25 seconds; a pending result contains `job_id` for `myman_app_job`. Native `app.wait` can continue while the MCP request returns pending. The app enforces the same grants, deletion confirmation, socket ownership, and resource lifecycle as CLI calls. No shell/pointer tool or permission-grant tool is introduced. Image pixels are returned only by explicit image/clipboard-image commands; other tools return attachment paths.

## Multi-agent collaboration (0.8.0)

The new `agent`, `machine`, `resource`, `bundle`, `handoff`, `lease`, `session transfer` and `collaboration events` commands use the same catalog and app MCP server. See [setup, four example workflows, permissions, revision guards, ownership and lifecycle](multi-agent-workflows.md). These commands require the updated app; public 1.1.64 does not provide them. Agent names are user-chosen, never product defaults.

## Quick tools, timers and reminders (My Man 1.1.95 / companion 0.11.0)

Check live `actions` before using these commands. On the selected Mac:

```sh
myman timer start --seconds 600 --json
myman reminder create --seconds 600 --message "Take pizza out" --json
myman tool evaluate --input "8am in Iceland" --json
myman tool evaluate --input "#fffffd" --json
myman calendar list --after 2026-09-23T00:00:00-04:00 --before 2026-09-24T00:00:00-04:00 --json
```

Timers and reminders appear in the same hover-expanding widget as human-created ones. Keep the returned timer `session_id` for `timer pause|resume|cancel --session-id ID`; inspect `timer status` first. Several timers can run at once; each `timer start` returns its own `session_id`, and `timer status` lists them all under `timers`. Use `reminder list` and `reminder cancel --id ID`; `reminder create --at ISO --message TEXT` accepts an absolute timestamp instead of seconds. Controls belong to the creating agent; human controls remain available. Existing library grants apply to timer/reminder/calendar actions. Calendar also requires human-granted macOS access.

Timers need My Man to stay open. Reminder results report `notification_scheduled` and `requires_app_open`; do not promise delivery while closed unless scheduling succeeded. `tool evaluate` is side-effect free and returns structured arithmetic, conversions, time zones, four-color palettes, checklists, bill splits, and timer/reminder previews. Evaluation never starts a timer or saves a note. Existing note/task/library/capture/recording commands remain supported. Keep request/job IDs and never replay interrupted mutations automatically.


## Timer and reminder sound (My Man 1.1.96 / companion 0.12.0)

Sound is on by default. Pass `--sound-enabled off` to `timer start` or `reminder create` for a silent countdown, or change an owned activity:

```sh
myman timer sound --session-id ID --enabled off --json
myman reminder sound --id ID --enabled on --json
```

Both status/list results include `sound_enabled`. Timer controls require the current session ID and creating agent; reminder controls require the creating agent. Human widget controls remain available. Reminder mute is persisted and updates scheduled notification sound. `tool evaluate` recognizes message-bearing timers and spoken numbers but remains side-effect free; agents must explicitly call the indicated creation action. Adaptive voice auto-submit is a human launcher behavior.
