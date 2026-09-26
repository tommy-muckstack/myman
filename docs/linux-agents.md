# Linux (agents)

MyMan's Linux companion runs locally on Ubuntu with Node.js 22+ and an X11 desktop (including Xvfb). It captures screenshots, annotates PNGs, creates Markdown notes, and searches a local MyManBrain. It is not a Swift UI port. It uses no cloud services, model downloads or API keys. Existing macOS executables and committed Brain bundles are unchanged.

## Install

Download `myman-linux-x64.tar.gz` from a release that includes the Linux companion, then:

```sh
tar -xzf myman-linux-x64.tar.gz
bash myman-linux-x64/scripts/install-linux.sh
export PATH="$HOME/.local/bin:$PATH"
myman doctor --json
```

The idempotent installer needs no sudo or npm install. It preserves existing owner grants and Brain documents, installs self-contained Node bundles into `~/.local/share/myman`, adds `~/.local/bin/myman`, and installs compatible tools under `~/MyManBrain/tools`. Node 22+ must already be available. `MYMAN_INSTALL_PREFIX` changes the default `~/.local` installation prefix. The tarball contains architecture-independent JavaScript; its release target is Linux x64.

Install whichever local dependencies you need (the installer only prints these commands):

```sh
sudo apt-get install imagemagick scrot x11-utils x11-xserver-utils git fonts-dejavu-core
sudo apt-get install tesseract-ocr xvfb xauth
```

ImageMagick is required for PNG normalization and annotation. Capture auto-detects **scrot → ImageMagick import → ffmpeg x11grab**, in that order. `xdpyinfo` reads the root dimensions; `xrandr` supplies monitor selectors when available. There is no automatic retry through another capture backend after a capture failure. `doctor` reports executables, display access, grants, and each workflow's dependency readiness separately. A Wayland-only desktop is unsupported; use its X11 session or Xvfb. No `grim` support is claimed.

Use the X11 desktop's `DISPLAY` and, if needed, `XAUTHORITY`. For a virtual desktop:

```sh
xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' myman screenshot --json
```

This captures the virtual desktop; start the application you want to capture on that same display.

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

The `myman` config directory must be mode `700` and `agents.json` mode `600`, owned by the current login. Missing config means all grants off; malformed or linked config fails closed. Global `enabled` and the relevant action group are checked on every invocation and again in workers. Recording remains unsupported even if its grant is set. Brain keyword retrieval and passive diagnostics do not require mutation grants. This is a same-login consent boundary, not a sandbox against an agent that already has arbitrary shell/file access. Mac named-agent tokens and machine routing are not implemented.

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

Bare `screenshot` captures the whole X11 desktop. `--display main`, monitor index, `id:N`, or an Xrandr monitor name selects one display. A region with `--display` is display-local, top-left; a region alone uses global bottom-left coordinates, matching the Mac CLI contract. `--coordinates` overrides that default. Regions must fit in one display; screenshots use scale 1. Monitor discovery returns selectors plus bottom-left `frame` and X11 top-left `x/y` metadata.

Annotations accept up to 100 arrows, boxes, highlights, text labels and pixelation operations. Explicit rectangles use integer image pixels, top-left. Colors and text `font_size` follow the shared schema. Crop applies last. A saved annotation gets a new ID; the original PNG and Markdown stay unchanged. `--dry-run` validates without rendering or saving an item. `--preview` renders a private temporary PNG without saving an item; previews expire after one hour and old files are cleaned on the next preview. Both still produce job receipts. No clipboard or editor is opened.

Screenshot results include the same ID, PNG/Brain paths, dimensions, scale, timestamp, timezone, attachment metadata, and job ID fields as the Mac capture subset. Tesseract OCR runs locally before the screenshot is indexed when available. `ocr_status` is `ready`, `unavailable`, or `failed`; missing OCR does not prevent capture. OCR is in the Markdown body and searchable by existing Brain tools. Live Text/OCR targeting, `capture ocr` bounding boxes, image/circle/callout overlays, window capture, native UI, clipboard, recording, meetings, dictation and the other Mac-only actions return `unsupported_on_platform`.

`search` and `library search` use Brain keywords, not semantic search. All existing read-only export queries (`collect`, `recent`, `read`, `image`, and kind aliases) are available. For MCP search, use `myman-brain`; the Mac's `myman_app_capture_search` action is unsupported. `--root` changes retrieval only; set `MYMAN_BRAIN_ROOT` in the process environment to choose the Linux writer's Brain. Mutations do not alter permissions or change that environment variable.

Use `--request-id UUID` for writes. The receipt is claimed before starting a detached local worker; identical retries return the original result, and different arguments with that ID return `ID_CONFLICT`. `--no-wait` returns a pending `job_id`; `job UUID` polls it, and `jobs` lists the latest 100 receipts. A waiting command that times out does not cancel or replay the worker. Receipts are stored privately in `${XDG_STATE_HOME:-~/.local/state}/myman/jobs`; they remain until the owner removes them. Removing receipts also removes deduplication history. A stopped worker becomes `interrupted`; inspect saved artifacts before issuing a new request.

Brain writes are serialized with `.myman-linux-write.lock`. An interrupted writer can leave this lock behind. Inspect `owner.json` and verify its process is no longer running before manually removing that lock. The companion does not discard locks or replay interrupted work automatically.

## Brain and MCP

The layout is the existing `notes/*.md`, `screenshots/*.md`, version-1 `catalog.json`, and Git history. Original PNGs live under `assets/captures`, with 400px thumbnails under `assets/capture-thumbnails`. Existing catalog entries and legacy Markdown exports are preserved. Git commits include only the new document/assets and catalog, leaving unrelated staged files untouched. No remotes are added and nothing is pushed. A Git failure after a successful save returns the saved ID and `git.committed: false`, so an agent can repair Git without duplicating the item.

Existing retrieval runs unchanged:

```sh
node integrations/brain/cli.mjs search '{"query":"review"}'
node "$HOME/MyManBrain/tools/server.mjs"
```

Start the Linux app server with `node ~/.local/share/myman/app-server.mjs` (or `~/MyManBrain/tools/app-server.mjs`). It exposes **the same MCP tool names** as the Mac server, including `myman_app_capabilities` and `myman_app_job`; capability discovery marks each action's `supported` status. Unsupported calls are MCP tool errors with the structured platform error. Both servers use local stdio, with no network listener. Captured text/images reach the requesting agent only when requested.

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

The `Linux agents` workflow runs the existing Brain suite, verifies both committed bundles, runs the source/bundled CLI and MCP contract under Xvfb, and tests an extracted tarball without npm dependencies. Published releases build and attach `myman-linux-x64.tar.gz` only after those checks pass. Mac hosts can run the portable contract tests, but Linux capture/OCR/text/installer tests require the Ubuntu job and are explicitly skipped elsewhere.
