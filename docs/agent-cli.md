# MyMan CLI for agents

The next app version adds a resource/action interface over the native action bridge introduced in 1.1.59. `myman actions` is the complete machine-readable catalog: names, argument schemas, effects, and required permission groups. `myman actions screenshot.edit` describes one operation. Every catalog action remains available as `myman invoke action.name '{"arguments":"here"}'`.

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

## Consent and permissions

Settings → Agents has **Allow local app commands**, plus four separate, default-off grants:

| Setting | Group | Actions |
| --- | --- | --- |
| Capture screenshots without the picker | capture | screenshot capture, shareable window list |
| Edit screenshots and create fonts | markup | import/edit images, remove background, create font |
| Control meetings, dictation and screen recordings | recording | start/control recordings, generate meeting notes, meeting auto-record preference |
| Create and change notes, tasks and library items | library | note/task/theme/library mutations, clipboard writes, safe settings changes |

Combined capture/markup requires both grants. The native bridge checks grants; neither JSON nor URL arguments can enable them. App settings mutation schemas exclude these grant keys. A menu-bar dot indicates that agent screenshot or recording access is enabled. Normal recording controls remain visible. No permanent “silent forever” grant is enabled by default; grants apply to this Mac login until the human turns them off. Session tokens are not implemented. Same-login processes are the trust boundary, not individual agents.

Stop/cancel commands remain available after revocation and still require the current session ID. Diagnostics remain available when commands are disabled. Delete (`item.delete`, `task.delete`, `history.clear`) requires library consent **and** `--confirm`. Changing a grant does not undo previously completed actions. Exported files remain readable independently of action settings.

| macOS permission | Needed for |
| --- | --- |
| Screen Recording / Screen & System Audio Recording | screenshots, shareable windows, screen video, meeting system audio |
| Microphone | dictation, meeting microphone, video `--mic on` |
| Camera | video `--webcam on` |
| Accessibility | existing dictation auto-paste and optional browser-window metadata |
| Full Calendar Access | existing calendar view and scheduling behavior |
| Input Monitoring | not required by the CLI; no pointer/key injection is provided |

macOS prompts remain real. A refusal returns `PERMISSION_REQUIRED` with the relevant permission; grant it in System Settings. The CLI never changes TCC settings. Brain MCP is read-only and has no app action tools. CLI operations are local; requesting agents may send returned excerpts or pixels to their model provider. MyMan does not automatically upload the Brain or send attachments/messages.

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

Retain the start result's session ID. Stop/cancel never silently picks another recording. There is no separate Zoom participant: MyMan records a call already running on this Mac. Meetings stop into processing, then Brain retrieval supplies the transcript/summary as it becomes available. Screen recordings require macOS 15+, return a `.mov` path/duration and `transcript_status: pending`; microphone defaults off, system audio on, webcam off. Webcam means the existing floating camera bubble. Cancel discards instead of restarting the picker. Dictation retains its existing paste/clipboard behavior and returns text plus its saved dictation ID when available.

Legacy bare `meeting`, `dictation`, and `record` retain their existing UI toggles. Bare `screenshot` opens the normal picker. They return `interactive: true, dispatched: ...`; they do not claim a completed capture. `--wait` completion and structured geometry belong to agent commands.

## Notes, library, tasks, themes, and fonts

```sh
myman note create --title "Follow-ups" --body-file - --json < body.md
myman note append --id note-ID --body "Another point" --json
myman note update --id note-ID --body-file body.md --expected-updated-at ISO8601 --json
myman library search --query "Jared" --kind meetings --json
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
myman font create --id shot-ID --name "Captured lettering" --json
myman font file --id note-FONT-ID --json
myman settings get --json
myman settings set --key automatic_themes --value false --json
```

Append is atomic and preserves a custom title; `--expected-updated-at` optionally rejects intervening changes. Replacement requires the timestamp from `library read`. Rich content is Markdown. Every mutation goes through app models and normal export/deletion lifecycle; never edit exported Markdown as a way to mutate the app. Font creation is the existing screenshot font workbench; missing glyphs may be inferred, not recovered exactly.

Library search/recent and theme/task lists use the read-only export snapshot, with the existing keyword/phrase matching and citation/pagination contract. They do not claim parity with native semantic ranking. `collect` retains all existing time/participant/theme/descriptor filters. `myman actions` lists the remaining first-class native actions.

## Results, jobs, and errors

With `--json`, stdout contains one JSON object, including errors. Logs belong on stderr. New resource/action results flatten `job.result` and include `job_id`/`launch_id`. Low-level `invoke` and `job` preserve the original job envelope for compatibility. Read tools preserve their citation/pagination envelope. `--no-wait` returns a pending job; `--wait-timeout SECONDS` bounds waiting (default 300, max 600). Timeout does not cancel work. Poll `myman job UUID` after timeout/disconnect; never blindly repeat a mutation. `--request-id UUID` is an idempotency key within one app launch, not across app restarts.

Exit codes: 0 success or intentionally pending; 2 OS permission missing; 3 cancelled; 4 agent access disabled; 5 invalid arguments/confirmation/conflicting revision or session; 6 operation/setup failure; 7 timeout. Error example: `{"ok":false,"error":{"code":"AGENT_DISABLED","message":"Enable capture access in My Man Settings → Agents for this action."}}`.

The local socket is owned by the login, directory mode 0700, socket mode 0600, peer-UID checked. Payloads, concurrent jobs, retained results, and socket read times are bounded. Results expire after restart/eviction; deletion invalidates cached content. `MYMAN_AGENT_SOCKET` supports an explicitly chosen owned socket for isolated developer verification, never remote TCP. Tests use a debug-only fixture app and a separate socket.
