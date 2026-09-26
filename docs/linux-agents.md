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

The `myman` config directory must be mode `700` and `agents.json` mode `600`, owned by the current login. Missing config means all grants off; malformed or linked config fails closed. Global `enabled` and the relevant action group are checked on every invocation and again in workers. The `recording` grant enables video-only screen recording. Brain keyword retrieval and passive diagnostics do not require mutation grants. This is a same-login consent boundary, not a sandbox against an agent that already has arbitrary shell/file access. Mac named-agent tokens and machine routing are not implemented.

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

Screenshot results include the same ID, PNG/Brain paths, dimensions, scale, timestamp, timezone, attachment metadata, and job ID fields as the Mac capture subset. Tesseract OCR runs locally before the screenshot is indexed when available. `ocr_status` is `ready`, `unavailable`, or `failed`; missing OCR does not prevent capture. OCR is in the Markdown body and searchable by existing Brain tools. Live Text targeting, image/circle/callout overlays, native UI, audio/webcam recording, meetings, dictation and the other Mac-only actions return `unsupported_on_platform`. (`capture ocr` boxes, window capture and the clipboard are covered below.)

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
```

X11 uses `ffmpeg` x11grab; Hyprland/Sway use `wf-recorder`. Regions follow the screenshot rules. Output is H.264 MP4 at 30 fps with the pointer drawn. `max_duration` defaults to 300 seconds. Only one recording can be active per login, and sessions are durable files under `${XDG_STATE_HOME:-~/.local/state}/myman/recordings`, so any later CLI or MCP process can stop them. Microphone, system audio, webcam and window recording remain Mac-only and return `unsupported_on_platform`.

Stopping saves `recordings/*.md`, a catalog entry, and a 400px thumbnail. The MP4 lives in `assets/recordings/`, which the companion adds to the Brain's `.gitignore`: videos stay on disk and are never committed, so the Brain's Git history stays small.

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
