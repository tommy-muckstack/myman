# Linux (agents)

MyMan's Linux companion runs locally on Ubuntu/X11 (including Xvfb) and Omarchy/Arch with Hyprland/Wayland, using Node.js 22+. It captures screenshots, annotates PNGs, and creates, edits, searches, pins, hides and deletes Markdown notes and captures in a local MyManBrain. It is not a Swift UI port. It uses no cloud services, model downloads or API keys. Existing macOS executables and committed Brain bundles are unchanged.

## Install

Download `myman-linux-x64.tar.gz` and `myman-linux-x64.tar.gz.sha256` from the same release, then:

```sh
sha256sum -c myman-linux-x64.tar.gz.sha256
tar -xzf myman-linux-x64.tar.gz
bash myman-linux-x64/scripts/install-linux.sh
export PATH="$HOME/.local/bin:$PATH"
myman doctor --json
```

The idempotent installer needs no sudo or npm install. It preserves existing owner grants and Brain documents, installs self-contained Node bundles into `~/.local/share/myman`, adds `~/.local/bin/myman`, and keeps executable tools out of `~/MyManBrain`. Node 22+ must already be available. For an older preview installation, change any MCP commands that point into `MyManBrain/tools` to the installed share directory; the new installer never executes or refreshes those legacy copies. `MYMAN_INSTALL_PREFIX` changes the default `~/.local` installation prefix. The tarball contains architecture-independent JavaScript; its release target is Linux x64.

### Arch and Omarchy package (AUR)

`packaging/aur/` holds the `myman-bin` package recipe. It installs the same release tarball into `/usr/lib/myman` (checked against the release checksum) and adds `/usr/bin/myman` and `/usr/bin/myman-setup`. Each person then runs `myman-setup` once, as themselves, to create `~/MyManBrain` and `~/.config/myman/agents.json` with every agent permission off. It never copies programs and never turns a permission on. Maintainers point the recipe at a new release with `packaging/aur/update.sh VERSION`.

```sh
makepkg -si        # from packaging/aur, or install myman-bin with your AUR helper
myman-setup
myman omarchy install   # Omarchy only
```

Install whichever local dependencies you need (the installer only prints these commands). Ubuntu/X11:

```sh
sudo apt-get install imagemagick scrot x11-utils x11-xserver-utils git fonts-dejavu-core
sudo apt-get install tesseract-ocr xvfb xauth
```

ImageMagick is required for PNG normalization and annotation. Capture auto-detects **scrot → ImageMagick import → ffmpeg x11grab**, in that order. `xdpyinfo` reads the root dimensions; `xrandr` supplies monitor selectors when available. There is no automatic retry through another capture backend after a capture failure. `doctor` reports executables, display access, grants, and each workflow's dependency readiness separately. Omarchy/Arch with Hyprland uses **grim**, with monitor discovery through `hyprctl`. Sway uses `swaymsg` plus grim. Wayland takes precedence over an Xwayland `DISPLAY`; a Wayland capture failure never silently switches to X11. Other Wayland compositors return a structured unsupported error.

### Omarchy / Arch

The same release archive and installer work on Omarchy. Install any missing dependencies with:

```sh
sudo pacman -S --needed nodejs-lts-jod git imagemagick librsvg grim ttf-dejavu
sudo pacman -S --needed tesseract tesseract-data-eng
```

An existing Node 22+ is sufficient; no need to replace it. `hyprctl` is supplied by Hyprland. Arch needs `librsvg` to load ImageMagick's SVG annotation module. Run MyMan from a terminal inside the desktop session. A remote agent must run as the desktop user with that session's `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, and `HYPRLAND_INSTANCE_SIGNATURE` (or `SWAYSOCK` on Sway). Preserve these when launching the MCP server; SSH alone does not supply them. No sudo is needed for capture. Use `myman doctor --json` to check desktop access, then enable the desired owner grants below and run `myman screenshot --json`.

Monitor selectors accept compositor output names (for example `DP-1`), `id:N`, or `main` (the focused output on Wayland). Coordinates are normalized to the desktop's top-left bounding origin, then exposed as global bottom-left or display-local top-left like X11. Wayland uses logical pixels and explicit grim scale 1, so fractional scaling, rotated outputs and monitors with negative layout positions remain consistent with annotation pixels. `native_scale` records the output's original scale; captured images are scale 1.

`myman windows list --json` lists visible windows on X11, Hyprland (`hyprctl -j clients`, active and special workspaces only, most recently focused first, id is the client address) and Sway (`swaymsg -t get_tree`). Each window has app, title, PID, workspace, a compositor `frame`, and a `region` in global bottom-left coordinates clipped to the display that holds the window's centre (`clipped` or `offscreen` when that applies). Pass the id to `myman screenshot --window-id ID --json` to capture just that window; the result echoes `window_id` and the window's app and title. `--window-id` cannot be combined with `--region` or `--display`.

### Readable capture notes

Every screenshot and recording note is written for both people and agents. The front matter has `kind`, `width`, `height`, `alt` (a plain-language description), `ocr_status` and `text_found`, plus `app` and `window_title` for window captures and `source_id` for marked-up copies. The body embeds the image with that description as alt text, gives the local capture time, and has a `## Text on screen` section. When a capture has no text, that section says so instead of being empty, and it names the missing dependency when text recognition is unavailable. CLI and MCP results return `title`, `alt_text`, `text_found` and a 280-character `text_excerpt`, so an agent can tell what it captured without opening the file. Recording notes state duration, size and that they have no audio, and embed the first frame when ffmpeg is available. Window titles are untrusted input and are flattened to one line before they reach Markdown.

### Omarchy theme-aware markup

When an annotation has no `color` (and no top-level `--color`), markup uses the active Omarchy theme from `${XDG_STATE_HOME:-~/.local/state}/omarchy/current/theme/colors.toml` (falling back to the legacy `~/.config/omarchy/current/theme/colors.toml`): arrows use `red`, boxes and text use `accent`, highlights use `yellow`, each falling back to `accent`. The annotate result then carries `theme: {name, source: "omarchy"}`, and `doctor` reports `markup_theme`. Explicit colors always win. Set `MYMAN_MARKUP_THEME=none` to keep the default `#FF375F`, or a path to a specific `colors.toml` to pin one theme.

References: [Omarchy manual](https://omarchy.org/manual/), [grim geometry and scaling](https://man.archlinux.org/man/grim.1.en).

Use the X11 desktop's `DISPLAY` and, if needed, `XAUTHORITY`. For a virtual desktop:

```sh
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK \
  xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' myman screenshot --json
```

This captures the virtual desktop; start the application you want to capture on that same display. Clearing the Wayland variables is necessary when launching Xvfb from an Omarchy/Wayland terminal, because ordinary capture deliberately prefers the real Wayland session over Xwayland.

## Owner-controlled permissions

The installer creates `${XDG_CONFIG_HOME:-~/.config}/myman/agents.json` with all grants off. The owner edits this file; neither CLI nor MCP exposes an enable-grant action. For example, to allow screenshots, annotation and note creation:

```json
{
  "version": 1,
  "grants": {
    "enabled": true,
    "capture": true,
    "markup": true,
    "recording": false,
    "library": true
  }
}
```

The `myman` config directory must be mode `700` and `agents.json` mode `600`, owned by the current login. Missing config means all grants off; malformed or linked config fails closed. Global `enabled` and the relevant action group are checked on every invocation and again in workers. The `recording` grant enables video-only screen recording. The `control` grant (off by default) lets `myman demo` start an app and drive the mouse and keyboard; recording alone never does. Brain keyword retrieval and passive diagnostics do not require mutation grants. This is a same-login consent boundary, not a sandbox against an agent that already has arbitrary shell/file access. Mac named-agent tokens and machine routing are not implemented.

### Optional administrator ceiling

An administrator can create **`/etc/myman/agents.json`** with the same version-1 JSON schema. The path is fixed: no environment variable, CLI flag or MCP argument can redirect it. When present, each effective grant (including `enabled`) must be true in **both** the system and user files. Omitted system grants mean false. No system file preserves the user-only model; a malformed, unreadable, linked, non-root-owned or group/world-writable system policy fails closed. `doctor` reports whether the system policy is present and displays the effective grants.

For example, after writing the desired ceiling to `system-agents.json`, the administrator can run:

```sh
sudo install -d -o root -g root -m 0755 /etc/myman
sudo install -o root -g root -m 0644 system-agents.json /etc/myman/agents.json
```

The installer does not run these commands, create the system policy, or enable any grants. The file and its parent directories must be root-owned and not writable by group or others. This prevents an unprivileged agent from increasing grants **through the trusted companion's configuration**. It does not prevent a same-user shell from replacing user-owned executables, editing job receipts, changing its environment, or bypassing MyMan to access the desktop directly. Keep runtime code outside Brain and restrict agent tools/accounts if you need an OS-enforced boundary; agents with sudo are outside this protection.

## CLI contract

The companion reuses the parser, JSON schemas, Brain reader, job unwrapping and exit-code rules from [agent-cli.md](agent-cli.md). Each JSON command writes exactly one object to stdout. Success exits 0; disabled grants 4, invalid arguments 5, unsupported/setup failures 6, timeout 7. Unsupported actions return `{"ok":false,"error":{"code":"unsupported_on_platform","message":"…"}}`.

```sh
myman screens list --json
myman screenshot --mode agent --display main --region 0,0,1000,700 --json
myman annotate --id shot-UUID --ops '[{"op":"box","rect":[20,20,300,100],"color":"#FF375F"},{"op":"text","at":[24,140],"text":"Review this","font_size":24},{"op":"crop","rect":[0,0,600,400]}]' --json
myman note create --title 'Review' --body 'Local observations' --json
myman search --query 'observations' --json
myman capture image --id shot-UUID --json
myman actions screenshot.edit --json
```

Bare `screenshot` captures the whole desktop. `--display main`, monitor index, `id:N`, or an Xrandr/compositor monitor name selects one display. A region with `--display` is display-local, top-left; a region alone uses global bottom-left coordinates, matching the Mac CLI contract. `--coordinates` overrides that default. Regions must fit in one display; screenshots use scale 1. Monitor discovery returns selectors plus bottom-left `frame` and normalized top-left `x/y` metadata.

Annotations accept up to 100 arrows, boxes, highlights, text labels and pixelation operations. Explicit rectangles use integer image pixels, top-left. Colors and text `font_size` follow the shared schema. Crop applies last. A saved annotation gets a new ID; the original PNG and Markdown stay unchanged. `--dry-run` validates without rendering or saving an item. `--preview` renders a private temporary PNG without saving an item; previews expire after one hour and old files are cleaned on the next preview. Both still produce job receipts. No clipboard or editor is opened.

Screenshot results include the same ID, PNG/Brain paths, dimensions, scale, timestamp, timezone, attachment metadata, and job ID fields as the Mac capture subset. Tesseract OCR runs locally before the screenshot is indexed when available. `ocr_status` is `ready`, `unavailable`, or `failed`; missing OCR does not prevent capture. OCR is in the Markdown body and searchable by existing Brain tools. Image/circle/callout overlays, native UI, webcam recording, live meeting notes and the other Mac-only actions return `unsupported_on_platform`; dictation start/stop points to Voxtype (see "Dictation saved to the Brain" below), and meetings are recorded with `myman meeting` (see "Meetings" below). (`capture ocr` boxes, window capture and the clipboard are covered below.)

## Library: read, search and edit

```sh
myman library search --query "pricing page" --kind screenshots --after 2026-09-01 --json
myman library read --id note-ID --json
myman note append --id note-ID --body "Reviewed" --expected-updated-at UPDATED_AT --json
myman note update --id note-ID --body-file body.md --expected-updated-at UPDATED_AT --json
myman note attach --id note-ID --source-id shot-ID --alt "Pricing table with the new tier" --json
myman library rename --id shot-ID --title "Pricing page" --expected-revision 1 --json
myman library pin|unpin|hide|unhide --id ID --json
myman library delete --id ID --confirm --json
```

`library read` returns the note body exactly as written (without its title heading), plus `revision`, `updated_at`, `pinned`, alt text and the source path. `library search` ranks exact phrases first, then items containing every word, then near spellings (one typo in words of five or more letters; `--lexical-only` turns that off). Each result says why it matched in `reasons`. Filters: `--kind`, `--after`/`--before` (capture time, before is exclusive), `--pinned-only`, `--limit`/`--offset`. Semantic search and themes are not available on Linux and return `unsupported_on_platform` instead of quietly returning keyword results.

Edits need the library grant. Replacing a note requires `--expected-updated-at` from `library read`; append accepts it too. Rename, pin, hide and delete accept `--expected-revision`. A stale value fails with `EDIT_CONFLICT` (exit 5) and never overwrites a newer change by a person or another agent. `--lease-id` is refused because named agents are Mac-only. Every edit is committed to the Brain's Git history with a plain message such as `MyMan Linux: append to note`.

Attached images are copied into `assets/note-images/NOTE-ID/`, so deleting the source never breaks the note. The Markdown image always has alt text: yours from `--alt`, the source screenshot's description, or the file name and size with an `ALT_TEXT_MISSING` warning asking you to describe it.

Hidden items move out of the catalog's exports into its `excluded` list. Every reader, `collect`, `recent` and search then omits them; `library read` says the item is hidden without returning its contents. Unhide restores it unchanged. Delete requires `--confirm`, removes the Markdown and the files it owns (image, thumbnail, recording, note images), and records the removal in Git; earlier committed versions remain in Git history.

`library related --id ID` lists up to 20 related items, each with a score and plain reasons: a marked-up copy and its source, a note that embeds a screenshot (attached images name their source under the image), the same app window, capture within ten minutes, and shared title words. There is no visual or semantic similarity on Linux.

Tasks use the Mac export format (`task-items/ID.md`), so `task list` and `collect --kinds tasks` read them unchanged. `task add --title T [--notes N] [--due DATE]` creates one; `task update`, `task complete` and `task reopen` change only the fields you pass and report them in `changed`; `--clear-due` removes a due date. Every task result carries `version`; pass it back as `--expected-version` to fail with `EDIT_CONFLICT` instead of overwriting. `task delete` requires `--confirm`. Due dates must be ISO dates or times; phrases such as "next Tuesday" are rejected so an agent resolves them first.

`search` (without `library`) keeps the plain Brain keyword query and still accepts `--root` for another Brain folder. `--root` changes retrieval only; set `MYMAN_BRAIN_ROOT` in the process environment to choose the Linux writer's Brain. Mutations do not alter permissions or change that environment variable.

Use `--request-id UUID` for writes. The receipt is claimed before starting a detached local worker; identical retries return the original result, and different arguments with that ID return `ID_CONFLICT`. `--no-wait` returns a pending `job_id`; `job UUID` polls it, and `jobs` lists the latest 100 receipts. A waiting command that times out does not cancel or replay the worker. Receipts are stored privately in `${XDG_STATE_HOME:-~/.local/state}/myman/jobs`; they remain until the owner removes them. Removing receipts also removes deduplication history. Worker receipts bind the PID to Linux `/proc/<pid>/stat` field 22 and the boot ID; a reused PID, zombie, previous boot or legacy PID-only receipt cannot keep a job alive. A stopped worker becomes `interrupted`; inspect saved artifacts before issuing a new request.

Brain writes are serialized with `.myman-linux-write.lock`. An interrupted writer can leave this lock behind. Inspect `owner.json` and verify its process is no longer running before manually removing that lock. The companion does not discard locks or replay interrupted work automatically.

## Screen recording (video only)

With the `recording` grant on (in the user file and, when present, `/etc/myman/agents.json`), agents can record the screen:

```sh
myman record start --display main --max-duration 30 --json   # returns session_id
myman record status --session-id rec-session-UUID --json
myman record stop --session-id rec-session-UUID --json       # finalizes and saves to the Brain
myman record cancel --session-id rec-session-UUID --json     # discards the video
myman record pause --session-id rec-session-UUID --json      # stops capturing; nothing is recorded while paused
myman record resume --session-id rec-session-UUID --json
myman record frames --id rec-UUID --count 6 --width 400 --json
myman record export --id rec-UUID --start 2 --end 20 --edits edits.json --json
```

Pausing closes the current segment and resuming starts a new one; stop joins the segments, so paused time never appears in the video and `max_duration` counts only recorded time. The status bar indicator shows `❚❚ REC` (class `paused`) while paused, and each pause and resume raises a notice.

`record frames` returns up to 12 still PNGs (evenly spaced with `--count`, default 6, or at `--times 0,2.5,5` in seconds) plus a contact sheet labeled with each time. They are temporary files that expire after an hour; nothing is added to the library. No grant is needed beyond reading the recording.

`record export` needs the recording grant. It writes a new library recording and never changes the source. `--start` and `--end` trim; `--max-bytes` tries full quality, then 1280x720, then 640x480, and fails with `SIZE_LIMIT_EXCEEDED` rather than cutting the clip short. `--edits` takes up to 20 timed edits whose times are in seconds of the source video: `caption` (bottom), `step` (top, with `number` 1 to 99), and `title` (centered, opaque) take `text`; `zoom` and `redact` take `rect` `[x,y,w,h]` in source pixels. Zoom is limited to 8x, zooms cannot overlap, and two overlays of the same kind cannot overlap in time. Redaction is applied before zooming, so a zoom never uncovers a redacted area. Text is drawn from an image, never passed through ffmpeg's text parser.

X11 uses `ffmpeg` x11grab; Hyprland/Sway use `wf-recorder` with `--no-damage` (when available) so idle screens still produce frames, stop finalizes promptly and video length matches wall time. `max_duration` is enforced on Wayland through GNU `timeout`, which sends the same finalizing SIGINT. If a recorder must be force-stopped, a video that still probes as readable is saved with a warning; otherwise the session is marked failed. Regions follow the screenshot rules. Output is H.264 MP4 at 30 fps with the pointer drawn. `max_duration` defaults to 300 seconds. Only one recording can be active per login, and sessions are durable files under `${XDG_STATE_HOME:-~/.local/state}/myman/recordings`, so any later CLI or MCP process can stop them. Microphone, system audio, webcam and window recording remain Mac-only and return `unsupported_on_platform`.

Stopping saves `recordings/*.md`, a catalog entry, and a 400px thumbnail. The MP4 lives in `assets/recordings/`, which the companion adds to the Brain's `.gitignore`: videos stay on disk and are never committed, so the Brain's Git history stays small.

### Cursor tracking

Every recording also logs the pointer, so later steps (auto-zoom, cursor effects, finished demos) know where the action is. A small companion process runs only while the recorder runs. It samples the pointer position about 20 times a second, keeping a sample only when the pointer moved, and pauses when the recording pauses. It also logs each click and each moment a key is pressed. **Key presses are logged as a time only, never which key.** Times are seconds into the finished video, and positions are pixels inside the recorded region.

Stopping saves the track as small JSON at `assets/recording-cursor/ID.json`. Like the video, the track stays on this computer: `assets/recording-cursor/` is added to the Brain's `.gitignore`, so pointer paths and typing times never enter Git history. (Tracks saved by earlier builds were committed; remove them from history with `git filter-repo` if that matters to you.) It is listed as `cursor_path` in the catalog and noted in the recording's Markdown, and deleting the recording deletes it too. `myman record cursor --id rec-UUID --json` (library grant) returns the clicks, the typing moments and `activity`: spans with a start, an end, a focus point and the reasons (`click`, `typing`, `pointer settled`), with nearby moments merged. `--full` adds every pointer position.

On Omarchy and Hyprland the position comes from `hyprctl cursorpos`. Hyprland does not report clicks to other programs, so there the track has movement only and says `clicks_tracked: false`. On X11 the position comes from `xdotool`, and clicks and typing come from `xinput` (package `xorg-xinput`). Sway does not expose the pointer, so the track says `pointer: unavailable` rather than guessing. `MYMAN_CURSOR_TRACK=0` turns tracking off.

### Polished demos: smooth auto-zoom

`myman record polish --id rec-UUID --auto-zoom --json` (recording grant) makes a polished copy of a recording and leaves the original untouched, the same way `record export` does. Auto-zoom reads the recording's cursor track and zooms on each `activity` span. It eases in over about 0.6 seconds, pans smoothly when the next moment is less than 2.5 seconds away, and eases back out. The zoomed window always stays inside the frame. Levels are `subtle` (1.4×), `normal` (1.8×, the default) and `strong` (2.4×), or any number from 1.1 to 4. Motion is computed per frame with sub-pixel precision, and frames outside a zoom are passed through unchanged.

Everything is a plain JSON recipe, so a result can be inspected, edited and rendered again:

- `--dry-run` returns the `plan` (zoom blocks with their pan points) and a `recipe` without rendering.
- `--recipe` takes JSON or a path to a JSON file, for example `{"zoom":{"level":"strong","moments":[{"start":2,"end":5,"x":640,"y":360}]}}`. Moments are in source seconds and source pixels. Passing back the returned `recipe` reproduces the same video.
- Recipe keys are `zoom.auto`, `zoom.level`, `zoom.ramp` (ease time, 0.2 to 2 seconds), `zoom.gap` (seconds between moments that still share one zoom) and `zoom.moments`. Unknown keys are errors, never ignored.
- A render allows up to 20 zooms, each panning to at most 8 spots. When auto-zoom finds more, it joins the closest neighbours; hand-written moments fail with a clear message instead.

The result includes `preview_times` (the middle of each zoom) to check with `myman record frames`. A recording made before cursor tracking has no track, so pass `zoom.moments` yourself. Output is 30 fps H.264 with no audio, like `record export`. This is Linux-only for now; the Mac has `record export` zoom edits, which cut in and out without easing.

### Polished demos: cursor polish

`myman record polish --id rec-UUID --cursor big --json` adds a soft highlight that follows the pointer and a ripple on every click. It combines with `--auto-zoom`, and the cursor layers zoom along with the picture. Sizes are `normal` (1.5×), `big` (2×) and `huge` (2.6×), or any number from 1 to 3.

For the best result, record with the real cursor hidden, then let polish draw a larger, smoother one:

```sh
myman record start --hide-cursor --region 0,0,1280,800 --json
# ...run the demo...
myman record stop --json
myman record polish --id rec-UUID --auto-zoom --cursor big --json
```

- `--hide-cursor` leaves the pointer out of the video but still logs its path. Polish then draws a crisp arrow at the chosen size, gliding along a smoothed path. Smoothing runs forward and backward, so the arrow never lags behind a click. A plain `record export` of such a recording has no cursor at all, so always polish it. X11 only for now; on Wayland the flag fails clearly instead of recording a cursor anyway.
- A normal recording already has the real cursor burned in. Polish then adds only the highlight and ripples around it and returns a warning if `size` or `smooth` was asked for.
- Recipe keys are `cursor.size`, `cursor.smooth` (0 for the raw path, up to 1, default 0.5), `cursor.highlight` and `cursor.ripple`. Each of the last two is `true`, `false`, or a colour such as `"#FFD60A"` (the default highlight is yellow, and the default ripple is white). Unknown keys are errors.
- Ripples mark where the click really landed, even when the drawn arrow is smoothed. Up to 60 are drawn per render. Clicks need the XInput tools; without them the result warns that there are no ripples.

The result adds `cursor: {drawn, highlight, ripples}` and `warnings`, and the returned `recipe` reproduces the same video. Check a few `preview_times` with `myman record frames`.

### Polished demos: background

`myman record polish --id rec-UUID --background ocean --json` puts the recording on the same backdrops the image editor and the Mac app's recording polish use: `dusk`, `ocean`, `meadow` and `slate` (diagonal gradients), or a custom colour with `--background-color '#1E293B'`. The video becomes a card with rounded corners (`--corner-radius`, 18 by default) and a soft shadow. The padding is 6% of the width (at least 32 pixels), so the output grows by the padding on every side and the video itself is never scaled down. It combines with `--auto-zoom` and `--cursor`, and the zoom happens inside the card. Drawing the background adds almost no render time, because the backdrop is drawn once as an image with a rounded window cut out.

- Recipe key `background` is a style name, or an object with `style` (`dusk`, `ocean`, `meadow`, `slate`, `custom` or `none`), `color` (only with `custom`, which is also assumed when `color` is given alone), `corner_radius` (0 to 200), `padding` (0 to 0.3 of the width) and `shadow` (`true`, `false`, or an opacity from 0 to 1; the default is 0.45). Unknown keys and styles are errors.
- The result adds `background: {style, output, video_box}`. `video_box` is where the video sits on the canvas, which helps when placing things later.
- `myman record polish --id rec-UUID --auto-zoom --cursor big --background ocean --json` is the usual full polish.

### Polished demos: music

`myman record polish --id rec-UUID --music upbeat --json` adds a background track. MyMan ships three tracks, and it composes them from code with no samples. That means they are free to use anywhere (CC0), and the same track sounds identical every time:

| Track | Feel | Loop length |
| --- | --- | --- |
| `upbeat` | Bright and energetic: synth arpeggio, soft beat, warm pad (116 BPM) | 33 s |
| `calm` | Relaxed and friendly: electric piano, gentle pad and bass, no drums (84 BPM) | 46 s |
| `cinematic` | Big and building: low strings, pulsing octaves, deep hits (72 BPM) | 53 s |

Each track loops seamlessly for longer videos. It is trimmed to the video's length and fades in (1.5 s) and out (2.5 s). You can also pass your own file by absolute path (`--music /home/me/song.mp3`); you are responsible for its licence. `--music-volume 0.3` sets the level between 0 and 1. By default the level is 0.8 when music is the only sound and 0.4 under narration.

When the recording has its own audio (a voice-over), the music ducks: it dips automatically while someone is speaking and comes back up in the pauses. Turn that off with `"duck": false` in a recipe.

Polishing now keeps the recording's own audio, even without music, the same way the Mac app does. Earlier Linux builds dropped it.

In a recipe, `music` is a track name, an absolute path, or an object: `{"track": "calm", "volume": 0.5, "fade_in": 1.5, "fade_out": 2.5, "duck": true, "start": 0}` (`file` replaces `track` for your own audio; `start` skips into the track by that many seconds). `--dry-run` lists the built-in tracks under `music_tracks`. The Mac app takes the same names; there, `myman record polish` composes the built-in track and hands the app a file, and the music plays at a lower level under recording audio instead of ducking.

### Polished demos: title and end cards

`--title "MyMan in 30 seconds"` and `--end "Try it: myman.dev"` add a card before and after the recording. A card is a full frame on the same backdrop as the video (slate when there is no background), with the text centred in white. Long lines shrink to fit. In a recipe, `title` and `end` are text or `{"text": "...", "subtitle": "...", "seconds": 2.5}`. The title lasts 2.5 s and the end card 2 s by default. Music plays across the cards, and the recording's own sound is shifted to start after the title. The result lists `cards.video_starts_at`, so an agent knows where the recording begins, and `preview_times` includes one frame from each card.

### Polished demos: one command

`myman demo --script steps.json --json` opens an app, records it, performs the steps and returns a finished demo. That demo has zooms, a smooth drawn cursor, click ripples, a backdrop, music, and title and end cards. A steps file looks like this:

```json
{
  "app": ["gnome-calculator"],
  "title": {"text": "Calculator in 10 seconds", "subtitle": "Recorded by an agent"},
  "end": "myman demo --script steps.json",
  "steps": [
    {"wait": 0.5},
    {"click": [120, 200]},
    {"type": "12*7", "at": [200, 60]},
    {"key": "Return"},
    {"wait": 1.5}
  ]
}
```

- **Look first.** `myman demo --look --app gnome-calculator --json` opens the app and returns a picture of its window (in `~/.cache/myman/demo-look`), a numbered copy with a faint grid every 50 points, and `elements`: each piece of text with the point to click, in the coordinates steps use. The app is closed again afterwards. That lets an agent write the steps from a plain description of the demo. Text is read with `tesseract`; icons, and some labels on dark or busy backgrounds, aren't listed, so read their points off the grid.
- **Steps.** `wait` (seconds), `move` and `click` (`[x, y]`, with `seconds` for the glide, `button` and `double`), `type` (text, with `cps` for characters per second and `at` for where the text appears), `key` (such as `Return` or `ctrl+s`) and `scroll` (positive scrolls down). Coordinates are relative to the top-left of the recorded area. Unknown keys are errors.
- **What gets recorded.** With `app` (or `--app`, which overrides it), MyMan starts the app, waits up to 15 s for its window, and records only that window. `window` picks the window by part of its title when the app opens several. `region` can also be `"display"` or `[x, y, width, height]` in top-left screen coordinates. The app is closed at the end unless you pass `"close": false`.
- **Only the app is on screen.** While it records, MyMan minimizes every other ordinary window so the demo stays on that app, then restores them and gives focus back to the window you were using. Panels, docks, notifications and the desktop are left alone. It needs a window manager that lists its windows (almost all do) and `xprop`; without them, other windows stay visible and the result says so in `warning`. `"focus": false` leaves other windows as they are. The result's `hidden_windows` says how many were hidden.
- **Zoom follows the steps.** Because MyMan performs every click and keystroke itself, it knows exactly when and where each happened. It zooms on each click, and on each burst of typing at `at` (or where it last clicked). Those clicks and keys are also written into the cursor track, so click ripples work even where input can't be detected.
- **Polish.** By default the demo uses `{"zoom": "steps", "cursor": {"size": "big"}, "background": "dusk", "music": "upbeat"}`. `polish` in the file overrides any of those keys (the same recipe `record polish` takes), and `"polish": false` keeps just the raw recording. The raw recording is always kept too, as `recording_id`.
- **Safety.** A demo starts a program and types and clicks into your desktop, so it needs the separate `control` grant as well as `recording`. `control` is off by default, is capped by `/etc/myman/agents.json` like every grant, and must be in a named agent's credential scopes. Recording and polishing run through `myman record start`, `record stop` and `record polish`. Keystrokes go to whichever window has focus, so don't use your computer while a demo runs. If a step fails, the recording is cancelled, not saved half-done. `--dry-run` checks the file and prints the plan, with the estimated length, without opening anything.

`myman demo` drives the app with `xdotool`, so for now it needs X11. On Wayland (Omarchy, Sway), record with `record start` and polish with `record polish`. The Mac app has no one-command demo yet.

## Brain and MCP

The layout is the existing `notes/*.md`, `screenshots/*.md`, version-1 `catalog.json`, and Git history. Original PNGs live under `assets/captures`, with 400px thumbnails under `assets/capture-thumbnails`. Existing catalog entries and legacy Markdown exports are preserved. Git commits include only the new document/assets and catalog, leaving unrelated staged files untouched. No remotes are added and nothing is pushed. A Git failure after a successful save returns the saved ID and `git.committed: false`, so an agent can repair Git without duplicating the item.

Existing retrieval runs unchanged:

```sh
node integrations/brain/cli.mjs search '{"query":"review"}'
node "$HOME/.local/share/myman/server.mjs"
```

Start the Linux app server with `node ~/.local/share/myman/app-server.mjs`. It exposes **the same MCP tool names** as the Mac server, including `myman_app_capabilities` and `myman_app_job`; capability discovery marks each action's `supported` status. Unsupported calls are MCP tool errors with the structured platform error. Both installed servers run from `~/.local/share/myman` (or the selected install prefix), never from the agent-writable Brain data tree. The marketplace package keeps its own code in its plugin installation, outside Brain. Both servers use local stdio, with no network listener. Captured text/images reach the requesting agent only when requested.

The root marketplace `mcp.json` dispatches `myman-app` by OS: the unchanged Mac bundle on macOS, the Linux bundle on Linux. `myman-brain` uses the exact same existing bundle on either platform. The separate GrokBot skill-only package remains Mac-specific; it is not changed by this Linux release.

## Development and verification

```sh
npm ci --ignore-scripts --prefix integrations/brain
npm ci --ignore-scripts --prefix integrations/linux
npm run bundle --prefix integrations/linux
npm run check-bundle --prefix integrations/brain
npm run check-bundle --prefix integrations/linux
xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' npm test --prefix integrations/linux
npm run package --prefix integrations/linux
```

The `Linux agents` workflow runs the existing Brain suite, verifies both committed bundles, runs the source/bundled CLI and MCP contract under Xvfb, tests the optional root-owned policy on a disposable Ubuntu runner, and tests an extracted tarball without npm dependencies. An Arch container runs the CLI/MCP contract with distro packages, Hyprland fixtures test monitor geometry and backend routing, and a real headless Sway compositor tests the Wayland screencopy path end to end. A physical Omarchy desktop smoke test remains useful for compositor and GPU-specific behavior. Published releases build and attach `myman-linux-x64.tar.gz` and its SHA-256 file only after those checks pass. Release actions are pinned to immutable commit SHAs, Node to 22.23.2, and npm installs use committed lockfiles. Ubuntu/Arch packages and the rolling Arch test image remain distro-managed runtime/test dependencies. The checksum detects corrupt or mismatched downloads; it is not a signature against an attacker who can replace both release assets. Mac hosts can run the portable contract tests, but Linux capture/OCR/text/installer tests require the Ubuntu job and are explicitly skipped elsewhere.

## Readable errors and output

Output is JSON whenever stdout is a pipe or `--json` is passed, so agents and scripts always get the same structured result. A person at a terminal (no `--json`) gets plain text instead.

When a command or flag is mistyped, the error keeps its code (`INVALID_ARGUMENTS`, `UNKNOWN_TOOL` or `UNKNOWN_ACTION`) and adds `suggestions`, for example `myman library serch` returns `"suggestions": ["myman library search"]`. Mac-only actions return `unsupported_on_platform` with an `alternative` field that says what to do on Linux instead. The MCP server returns the same messages.

## Seeing when an agent captures your screen

Every agent screenshot and every recording start, stop and cancel raises a desktop notification through `notify-send` (mako on Omarchy, dunst, GNOME and KDE all show it). The recording notice stays on screen until the recording ends, and it includes the stop command. Agents can't turn these notifications off; there is no flag or environment variable for it. Install `libnotify` (Arch) or `libnotify-bin` (Debian/Ubuntu) if `notify-send` is missing.

For a status-bar light, `myman indicator` prints Waybar-style JSON. The text is empty when nothing is happening, `● SHOT` for a few seconds after a screenshot, and `● REC 0:12` while recording. `class` is `idle`, `capture` or `recording`, and the tooltip includes the stop command.

On Omarchy, add this module to `bar.layout.right` in `~/.config/omarchy/shell.json`:

```json
{ "id": "myman", "type": "command", "exec": "myman indicator", "interval": 2, "tooltip": "MyMan agent capture" }
```

On Waybar, add `"custom/myman": { "exec": "myman indicator", "return-type": "json", "interval": 2, "signal": 9 }` to your config and set `MYMAN_WAYBAR_SIGNAL=9` in the agent's environment so the light updates instantly instead of on the next poll.

## Compare screenshots and find text

`myman capture compare --before-id ID --after-id ID --json` returns the same fields as the Mac app: `changed_pixels`, `compared_pixels`, `change_ratio`, changed `regions` (image-pixel top-left rectangles, grouped in 32-pixel tiles), `changed_text` (`added` and `removed` OCR lines), and a side-by-side PNG in `path` that is deleted after an hour. Both screenshots must be the same size. `--ignore-rects '[[x,y,w,h]]'` skips areas such as a clock, and `--threshold` (0 to 255, default 20) sets how different a pixel must be to count. It needs the library grant because it reads two saved items. Neither screenshot is changed.

`myman capture targets --id SHOT-ID --query TEXT --json` finds text on a screenshot and returns regions with stable IDs (`ocr-…` for lines, `word-ocr-…` with `--granularity word`) and exact pixel rectangles you can pass to `annotate`.

## Point markup at text, capture and mark up in one step, import images

Instead of pixel geometry, an annotation can name what it points at: `{"type":"box","target_text":"Cancel"}` or `{"type":"arrow","target_region":"word-ocr-…"}`. The rules match the Mac app. An exact word match (ignoring case and accents) wins, then a substring of a line. The box grows by 6 pixels on each side, and an arrow points at the center, with `from` placed automatically if you leave it out. Use one of `target_text` or `target_region`, and no `rect` or `to`. If the text appears more than once, the answer is `AMBIGUOUS_TARGET` with up to 50 candidates and a total in `details`; if it is not found, `TARGET_NOT_FOUND`. Nothing is saved in either case. Pick a candidate's `id` and retry with `target_region`. This also works with `--dry-run` and `--preview`.

`myman capture-markup --mode agent [--region x,y,w,h] --ops-file ops.json --json` needs both the capture and markup grants. It captures, applies the operations, and saves only the finished image, like the Mac. The screen-capture notice fires as for `screenshot`.

`myman capture import --path /abs/file --json` needs the markup grant. It accepts PNG, JPEG, WebP or GIF, detected from the file's contents rather than its name, up to 64 MB. It saves the image as a normal PNG capture with OCR. Other formats, such as SVG or PDF, are refused, so a file never reaches ImageMagick's script or vector readers.

## Timers and reminders

With the library grant on (the same grant the Mac requires), agents can set countdown timers and reminders:

```sh
myman timer start --seconds 300 --json                      # returns session_id
myman timer pause|resume|cancel --session-id ID --json
myman timer sound --session-id ID --enabled false --json
myman timer status --json                                   # newest timer plus every active one
myman reminder create --message "Stand up" --seconds 1800 --json
myman reminder create --message "Call Sam" --at 2026-10-01T09:00:00-04:00 --json
myman reminder list --json; myman reminder cancel --id ID --json
```

When a timer finishes or a reminder is due, a desktop notice appears (it stays until dismissed) and a sound plays unless `sound_enabled` is false. There is no on-screen countdown widget; `timer status` and the result's `remaining_seconds` report time left. `at` must include a time-zone offset or `Z`.

Each deadline is armed as a transient systemd user timer when a user manager is running, so it fires even if no MyMan process is open. Otherwise a small detached process waits for it (`scheduler: "process"`, `survives_logout: false`). Either way, anything that came due while nothing was waiting (after a reboot, say) is delivered the next time any timer or reminder command runs. Pausing or canceling bumps a generation number, so an old schedule never fires. Only the agent that created a timer or reminder can change it; agents are told apart by their named credential, or by `MYMAN_AGENT_ID` (default `agent`) when they have none. State lives in `${XDG_STATE_HOME:-~/.local/state}/myman/quick-tools.json`, mode 600.

## Several agents on one computer

A person gives each agent its own credential. This is never an agent action: `myman agents` refuses to change anything unless it runs at an interactive terminal without `MYMAN_AGENT_TOKEN`, and it asks the person to type a confirmation.

```sh
myman agents add "Research bot" --scopes capture,markup,library   # prints the token once
myman agents list                                                 # names, scopes, never tokens
myman agents revoke ID
myman agents require off   # let agents without a credential work again
```

Scopes are `capture`, `markup`, `recording`, `library`, `microphone` and `control`. They only narrow access: the grants in `agents.json` and the optional `/etc/myman/agents.json` ceiling still apply to every agent. As on the Mac, issuing the first credential makes credentials required, so an agent without one gets `IDENTITY_REQUIRED`. The registry lives next to the grants file as `identities.json` (mode 600) and stores only a SHA-256 digest of each token. Like the Mac, credentials tell cooperating agents apart; they do not sandbox programs running under the same login.

The agent puts its token in `MYMAN_AGENT_TOKEN` in its host environment (never in a prompt). Then:

```sh
myman agent whoami --json          # id, name, scopes, machine
myman agent list --json            # other agents' IDs and names
myman bundle create --title "Login bug" --item-ids SHOT-1,SHOT-2 --members OTHER-ID --json
myman handoff create --bundle-id B --recipient OTHER-ID --instruction "Check these for the error" --json
myman handoff update --id H --expected-revision 1 --state accepted --json   # recipient; then completed/failed
myman collaboration events --after-cursor 0 --json
myman lease acquire --resource clipboard --seconds 60 --json   # pass --lease-id on the write, then release
myman session transfer --session-id S --recipient OTHER-ID --json
```

Bundles hold item references and revisions, not copies; reading one marks items that changed or disappeared. A handoff only records an offer. It never launches or messages the other agent, and its instruction is data, not a command. A live lease on the clipboard or an item blocks every other agent's write to it. A recording belongs to the agent that started it until that agent transfers it to another with the `recording` scope. `--machine ID` (or `MYMAN_MACHINE_ID`) makes a command fail with `WRONG_MACHINE` on any other computer. Coordination state is `${XDG_STATE_HOME:-~/.local/state}/myman/collaboration.json`, capped at 8 MB with the Mac's limits (100 bundles, 200 handoffs, 1000 events).

## Show your agents part of the screen (Omarchy and any Linux desktop)

`myman show` is for the person at the computer. Drag over part of the screen and MyMan saves just that area to the Brain, marked `shown_by: person` and tagged `shown`, with an optional `--note` saying what to look at. A notification confirms it. Agents find it with `myman library search --query shown --json` and open it with `myman library read --id ID --json`. It uses slurp and grim on Wayland, and slop with ImageMagick or `scrot --select` on X11. Pressing Escape saves nothing. It refuses to run with an agent credential (`HUMAN_REQUIRED`); agents keep using `myman screenshot`, which the owner grants control.

On Omarchy, `myman omarchy install` (run by the person, in a terminal) adds:

- **SUPER + SHIFT + PRINT** for `myman show`, as a clearly marked block at the end of `~/.config/hypr/bindings.lua`. Omarchy's own PRINT keys are untouched.
- A **MyMan** menu under Trigger in the Omarchy menu, merged from `~/.config/omarchy/extensions/omarchy-menu.jsonc`, with rows to show your agents part of the screen, open the Brain folder, check setup, edit agent permissions and list agent credentials.

It reloads the menu and Hyprland, keeps your own bindings and menu rows, writes through symlinked dotfiles, and installing twice changes nothing. `myman omarchy remove` takes out exactly those blocks, and `myman omarchy status --json` reports what is installed. Neither command changes agent permissions.

## Dictation saved to the Brain (Voxtype)

On Linux, people dictate with [Voxtype](https://github.com/peteonrails/voxtype), the local Whisper dictation Omarchy offers on first run (F9 to hold and talk, or Super+Ctrl+X to toggle). Speech is recognized on the computer; nothing goes to the cloud. MyMan does not record the microphone for dictation.

`myman dictation connect` (run by the person, in a terminal, or from the Omarchy menu under Trigger, then MyMan) adds a clearly marked `[output.post_process]` block to `~/.config/voxtype/config.toml` and restarts Voxtype if it is running. After that, every dictation is typed exactly as before and a copy is saved to `dictations/` in the Brain, in the same format the Mac app exports (`created`, `captured_local`, `tz`, and the text as the body). If you already had a Voxtype cleanup command, MyMan runs it first and saves its output, so nothing about your dictation changes. The text is printed back immediately and the Brain save happens in a separate background process, so typing is not delayed, and a failed save never loses the dictation.

Agents read dictations with `myman library search --kind dictations --json` (library grant). A process holding an agent credential cannot add dictations. `myman dictation status --json` shows whether it is connected; `myman dictation disconnect` removes the block and puts back your original cleanup step. Other `dictation` commands return a readable pointer to Voxtype instead of a bare "unsupported".

## Meetings

`myman meeting start --title "Weekly sync"` records a call that is already happening on this computer. It never joins a call. MyMan records two tracks with ffmpeg through PipeWire: your microphone, labeled **You**, and what the computer plays, labeled **Others**. Use `--no-system-audio` to record only the microphone. A notification appears and the indicator shows `● MIC` with a timer the whole time. Recordings stop on their own after 4 hours (`--max-minutes` sets a shorter limit).

`myman meeting stop` saves the meeting to `meetings/` in the Brain right away, in the same format the Mac app exports (`started`, `ended`, `participants`, `transcript_status`, and a `## Transcript` of `**You** [m:ss]: …` lines). The transcript is then written on this computer in the background. Each track is split at pauses and transcribed with Whisper, and the note is updated from `transcript_status: processing` to `ready`. Nothing is uploaded, and MyMan never downloads a model. It uses, in order, the command in `MYMAN_TRANSCRIBE_COMMAND` (given a WAV path, it prints text), `whisper-cli` from whisper.cpp with the model in `MYMAN_WHISPER_MODEL` or the first `ggml-*.bin` in Voxtype's or whisper.cpp's model folder, or `voxtype transcribe`. On Omarchy, if you set up Voxtype dictation, meetings already work with no other install. If no engine is found, the note says so (`transcript_status: unavailable`), the audio is kept, and `myman meeting transcribe ID` retries later. Otherwise the audio is deleted once the transcript is saved, unless you pass `--keep-audio`. `myman meeting cancel` stops and saves nothing.

The person at the computer can always record their own meeting from a terminal or the Omarchy menu (Trigger, then MyMan). Agents need both the `recording` grant and the new `microphone` grant, which is off by default and capped by `/etc/myman/agents.json` like the others, and a named credential must include both scopes. An agent must pass the `--id` returned by `meeting start` to stop or cancel. Agents read meetings with `myman library search --kind meetings --json`. The microphone and system audio devices can be changed with `MYMAN_AUDIO_FORMAT`, `MYMAN_MIC_DEVICE` and `MYMAN_SYSTEM_DEVICE` (defaults `pulse`, `default` and `@DEFAULT_MONITOR@`).
