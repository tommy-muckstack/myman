# Folder bridge: app actions without the socket

Some agents cannot reach the local command socket. A cloud agent that works on a Mac through a desktop app runs its shell in a Linux sandbox: it has no `/tmp/myman-<uid>/control.sock`, no localhost, and it cannot launch Mac apps. Local MCP servers may also be blocked by an organization's policy. What such an agent does have is read and write access to a folder the person connected, such as `~/MyManBrain`.

The folder bridge lets that agent run the actions in [`actions.json`](../integrations/brain/actions.json) by writing a file and reading the answer. Requests go through the same dispatcher as the CLI and the app MCP server, so schemas, grants, named credentials and receipts behave the same.

## Turning it on

Only a person can, in **Settings → Agents → Accept commands through the Brain folder**. It starts off. There is no CLI command, action, MCP tool or flag for it, and `myman agents grant` does not cover it.

The bridge runs only while both that switch and **Allow local app commands** are on. While it is off the app does not read the inbox, creates nothing, and runs nothing. If the folder exists from an earlier time, `manifest.json` says `"enabled": false`.

This switch widens who can send commands. The socket accepts only processes under your Mac login. The folder accepts anything that can write to it, including a cloud agent and any sync tool. That is why the bridge has its own switch and asks before sensitive actions.

## Layout

```
~/MyManBrain/agent/
  manifest.json     app version, enabled flag, grants, every action with its schema and tier
  heartbeat.json    rewritten every 10 seconds while the watcher runs
  inbox/<id>.json   requests, written by the agent
  outbox/<id>.json  answers, written by the app
  artifacts/<id>/   files an action produced
  audit.log         one JSON line per request, prompt, answer and result
```

The folder has a `.gitignore` of `*`, so nothing in it is committed when you push your Brain. Answers and artifacts are removed after a day, and all of them are removed when a capture is deleted or hidden, like other retained agent results.

## Request

Read `manifest.json` first. Then write the request under a name that starts with a dot and rename it, so the app never reads half a file:

```json
{"id": "6f1c2d1e-6f0b-4d0e-9a57-0c0a5f2f7d10", "action": "screenshot.capture", "args": {"display": "main"}, "created": "2026-11-24T17:20:00Z"}
```

```sh
id=$(uuidgen | tr A-Z a-z)
printf '{"id":"%s","action":"app.status","args":{},"created":"%s"}' "$id" "$(date -u +%FT%TZ)" > "agent/inbox/.$id.json.tmp"
mv "agent/inbox/.$id.json.tmp" "agent/inbox/$id.json"
```

| Field | Rule |
| --- | --- |
| `id` | A new UUID. The file is `inbox/<id>.json`. An id runs once. |
| `action` | A name from `manifest.json`. |
| `args` | An object that matches the action's `inputSchema`. May be omitted for `{}`. |
| `created` | ISO 8601 with a time zone, or Unix seconds. More than 10 minutes from the Mac's clock is refused. |
| `credential`, `machine_id` | Only when this Mac requires named agents. Never logged or echoed. |

Any other key, a file over 1 MiB, or a name that is not `<uuid>.json` is refused.

## Response

The app writes `outbox/<id>.json`, then removes the request.

```json
{"ok": true, "id": "…", "action": "screenshot.capture", "result": {"id": "shot-…", "path": "/Users/…/shot.png", "width": 2400}, "artifacts": ["artifacts/6f1c…/shot.png"]}
```

```json
{"ok": false, "id": "…", "action": "note.create", "error": {"code": "AGENT_DISABLED", "message": "Enable library access in My Man Settings → Agents for this action.", "hint": "Agents cannot enable this. A person turns it on in My Man Settings → Agents."}, "artifacts": []}
```

`error` has the same `code` and `message` as the CLI, plus a `hint` saying what to do next. `result` is what the CLI returns for that action.

**Artifacts.** Files a result points at (screenshots, recording exports, frames, previews) are copied to `artifacts/<id>/` and listed by path relative to the bridge folder. Meeting notes are also written as `notes.md`. Image data is never inlined: where the CLI returns base64, the bridge returns `{"mimeType": "image/png", "artifact": "artifacts/<id>/inline.png"}`. Paths inside `result` still name the file on the Mac; use `artifacts`. A file is copied only from the folders My Man saves to, only if it is an image, video, audio or document type, and only up to 1 GiB and 32 files per request. Anything left out is listed in `artifacts_skipped` with the reason.

**Bridge error codes.** `AWAITING_USER`, `USER_DENIED`, `APPROVAL_EXPIRED`, `STALE_REQUEST`, `ID_ALREADY_USED`, `INVALID_REQUEST`, `BRIDGE_DISABLED`, and every code the CLI returns (`AGENT_DISABLED`, `UNKNOWN_ACTION`, `INVALID_ARGUMENTS`, `PERMISSION_REQUIRED`, `IDENTITY_REQUIRED`, `APP_RESTARTED`, and so on).

A repeat of an id that already has an answer is dropped and the first answer is left as it was. Work interrupted by an app restart is reported as `APP_RESTARTED` and never run again.

## Permission tiers

Each action in `manifest.json` has a `tier`, its `permissions` (the grants from Settings → Agents), `approval_group` and `requires_confirm`.

| Tier | What it takes | Examples |
| --- | --- | --- |
| `open` | The bridge is on. | `app.status`, `app.doctor`, `screens.list`, `item.read`, `capture.search` |
| `grant` | The listed grants are on in Settings → Agents. | `note.create` (library), `screenshot.edit` (markup), `calendar.freebusy` (calendar_read) |
| `approval` | The grants, and the person allows it in a prompt. | see below |

The existing grants are unchanged and still apply to every request. The prompt is extra, and only the bridge has it. These ask:

| Group | Actions |
| --- | --- |
| capture | anything that needs the capture grant: `screenshot.capture`, `screenshot.capture_markup`, `windows.list`, `capture.scroll.start` |
| recording | anything that needs the recording grant: `recording.start`, `recording.export`, `recording.polish`, `meeting.start`, `meeting.notes`, `dictation.start`, and the rest |
| control | `demo.run` |
| clipboard | `clipboard.read`, `clipboard.write`, and any action sent with `"clipboard": true` |
| sharing | `share.publish` |
| delete | every action marked destructive: `item.delete`, `task.delete`, `history.clear`, `theme.dismiss`, `bundle.delete`, `brief.delete` |

Stopping is never held back, the same as with a revoked grant: `recording.stop`, `recording.cancel`, `recording.pause`, `meeting.stop`, `meeting.discard`, `dictation.stop`, `dictation.cancel` and the other cleanup actions run without a prompt. Deletes still need `"confirm": true` as well.

While the prompt is open the outbox holds:

```json
{"ok": false, "pending": true, "error": {"code": "AWAITING_USER", "message": "Waiting for the person to allow or deny this in My Man.", "hint": "…"}, "artifacts": []}
```

Read the file again; do not send the request again. It becomes the result after **Allow once** or **Allow for 10 minutes**, `USER_DENIED` after **Deny** or closing the window, and `APPROVAL_EXPIRED` if nobody answers within 10 minutes of `created`. **Allow for 10 minutes** covers later requests in the same group and is not offered for deletes. The window floats without taking keyboard focus, so a key typed in another app cannot allow a request.

## From the CLI

`--bridge` (or `MYMAN_BRIDGE=1`) makes the CLI send through the folder instead of the socket. The companion in the Brain needs only Node 22, so it runs in a sandbox that has the folder mounted:

```sh
node /mnt/MyManBrain/tools/cli.mjs --bridge --root /mnt/MyManBrain doctor --json
node /mnt/MyManBrain/tools/cli.mjs --bridge --root /mnt/MyManBrain actions --json
node /mnt/MyManBrain/tools/cli.mjs --bridge --root /mnt/MyManBrain screenshot --mode agent --display main --json
node /mnt/MyManBrain/tools/cli.mjs --bridge --root /mnt/MyManBrain job 6f1c2d1e-6f0b-4d0e-9a57-0c0a5f2f7d10 --json
```

The folder is `<root>/agent`, or `MYMAN_BRIDGE_DIR`. Results gain `artifacts` when an action produced files. A command that is still waiting for the person when `--wait-timeout` ends returns `AWAITING_USER` with its `job_id` (exit code 7); poll it with `job`. `jobs` is not available through the folder.

`doctor` reports a `bridge` block whenever the folder exists: `exists`, `writable` (it creates and removes a dot file in the inbox), `enabled`, and `heartbeat.alive` (written within 30 seconds). With `--bridge`, each problem becomes a `next_steps` entry for the person. `actions --json` reads `manifest.json`, so it reflects the running app.

## What is not here yet

A stdio MCP server generated from `actions.json` already ships as `myman-app` (`tools/app-server.mjs`). It talks to the socket. Pointing it at the folder is a small follow-up, useful if a policy that blocks local MCP servers changes.
