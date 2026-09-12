# MyMan Brain plugin

Read-only MCP retrieval and a local app CLI for MyMan meeting transcripts,
notes, tasks, dictation, Themes, recording transcripts and screenshot OCR/images.
The companion reads `~/MyManBrain` and returns JSON with citations and pagination.
CLI mutations use the running app's same-login Unix socket; they never write the
database or exported Markdown directly.

## Explicit app actions

MyMan 1.1.60 adds resource/action commands, default-off granular consent,
and stable JSON errors. All original 1.1.59 action names remain available through
`invoke`; the new native consent rules apply to them too. **Version 0.4 removes
app-action tools from Brain MCP.** Use the app CLI for capture and mutations.

```sh
myman doctor --json
myman actions
myman screenshot --mode agent --display main --json
myman annotate --id shot-ID --ops '[{"op":"box","rect":[20,20,200,100]}]' --clipboard --json
myman record start --mic off --json
myman record stop --session-id RETURNED-ID --json
```

See [command reference and permissions](../../docs/agent-cli.md),
[whole-app parity](../../docs/agent-cli-parity.md), and
[GrokBot packaging/status](../../docs/grok-bot-marketplace.md).
Settings → Agents controls capture, markup, recording and library writes separately.
Delete commands also require `--confirm`. Do not replay a mutation after a timeout:
poll its job ID. Capture/markup returns absolute media paths; OCR/export can still
be processing. The agent's own attachment mechanism returns files to the user.

## Use the companion shipped with MyMan

Open the updated app once. The Brain includes a standalone CLI and local MCP
server under `~/MyManBrain/tools/`. Node.js 22+ is required; no clone or npm
install is needed for these bundled files.

```bash
node ~/MyManBrain/tools/cli.mjs screenshots --meeting "Jared demo" --exclude-tag slide-deck --unique
node ~/MyManBrain/tools/cli.mjs screenshots --after "2026-09-11T09:00:00-04:00" --before "2026-09-11T10:00:00-04:00" --app Chrome --tag web-app
node ~/MyManBrain/tools/cli.mjs meetings --participant Jared --after "2026-09-01T00:00:00-04:00"
node ~/MyManBrain/tools/cli.mjs recordings --query "pricing"
node ~/MyManBrain/tools/cli.mjs status
node ~/MyManBrain/tools/cli.mjs --help
```

`--meeting` accepts an ID, export path, or title/participant/topic description.
An ambiguous description returns candidates; select a returned ID/path rather
than silently taking the most recent call. `--unique` chooses one representative
per known visual sequence; omit it when small changes matter. Queries return
JSON metadata, not image bytes. `image` with `size: thumbnail` explicitly returns
a compact preview; use `size: original` for detailed visual inspection.

The companion works while the app is closed using the last export. With another
Brain folder, pass `--root /absolute/path/to/MyManBrain` or set `MYMAN_BRAIN_ROOT`.
A missing folder is an error, not an empty history. Older Brain folders have
limited coverage; open the updated app to regenerate its catalog and tools.

For source development instead, run `npm ci --ignore-scripts --prefix
integrations/brain`, then `node integrations/brain/cli.mjs status`. After edits,
run `npm run bundle --prefix integrations/brain`; committed resource bundles
are checked in CI and ship through SwiftPM with third-party licenses.

## Use with Grok Bot

Grok Bot's agent computer normally runs in the cloud. The companion and Brain
must be accessed through **Execution on Local Computer** on your Mac. The
desktop's existing execution policy applies. Node must be available to that
local process; use the absolute Node executable path if its PATH differs from
your interactive terminal.

Give Grok Bot this setup prompt:

> MyMan is installed on my Mac, and its companion is at
> `~/MyManBrain/tools/cli.mjs`. Use your local-computer
> execution capability on that Mac to run `node` with that file and `status`.
> Then run `recent` with the JSON argument `{"kind":"meetings","limit":3}`.
> Tell me the three meeting titles and dates, with source paths. Read only the
> files needed to answer; don't copy my Brain to the cloud. If local execution
> is unavailable, tell me instead of running these commands on the cloud computer.

The packaged [skill](../../skills/myman-brain/SKILL.md) explains retrieval and
citation behavior and can be supplied to the Bot as instructions. This route
does not depend on assuming Grok Bot can launch a Mac-local stdio MCP server.
We have not verified Grok Bot marketplace installation or a live Bot invocation
in this checkout. Cursor IDE plugin support alone does not establish that.

## Use with a local MCP client

The repository root contains a portable Agent Plugins `plugin.json`, `mcp.json`,
and `skills/`. The manifest points at the bundled server (no npm install required). A compatible local client can load
the repository as a plugin. For Cursor local development, link the checkout:

```bash
mkdir -p ~/.cursor/plugins/local
ln -s /absolute/path/to/myman ~/.cursor/plugins/local/myman-brain
```

Replace the example checkout path; don't overwrite an existing installation.
Reload Cursor and check Customize. Team policy may restrict local plugins.

For clients using native MCP configuration instead of Agent Plugins, use:

```json
{
  "mcpServers": {
    "myman-brain": {
      "command": "node",
      "args": ["/Users/YOUR_USERNAME/MyManBrain/tools/server.mjs"]
    }
  }
}
```

Replace YOUR_USERNAME with the Mac account name. Use an absolute path for Node too if required by the client's environment. A
remote/cloud client cannot see the Mac's files merely by loading this config.
There is no HTTP listener, tunnel, hosted connector, account, or OAuth flow in
this version.

## Tools and command equivalents

| MCP tool | CLI command | Arguments |
| --- | --- | --- |
| `myman_brain_status` | `status` | none |
| `myman_brain_search` | `search` | `query`, optional `kind`, `limit` |
| `myman_brain_recent` | `recent` | optional `kind`, `limit`, `offset` |
| `myman_brain_collect` | `collect` | optional `kinds`, `query`, `match`, `after`, `before`, `during`, `date_field`, `participants`, `theme`, `pinned_only`, `state`, `limit`, `offset` |
| `myman_brain_meetings` | `meetings` | optional `query`, `participants`, `started_after`, `started_before`, `limit`, `offset` |
| `myman_brain_screenshots` | `screenshots` | optional `meeting`, `after`, `before`, `app`, `tags`, `exclude_tags`, `unique`, `query`, `limit`, `offset` |
| `myman_brain_meeting_screenshots` | `meeting_screenshots` | `meeting_path`, optional `limit`, `offset` |
| `myman_brain_read` | `read` | `path`, optional `offset`, `max_chars` |
| `myman_brain_image` | `image` | screenshot export `path`, optional `size`: `original` or `thumbnail` (requires app catalog) |
| `myman_brain_tasks` | `tasks` | optional `state`: `open`/`done`/`all`, `limit`, `offset` |

Kinds: `meetings`, `notes`, `recordings`, `screenshots`, `dictations`, `themes`, `tasks`, `people`,
`vocabulary`. Searches are case-insensitive and require all keyword terms.
Result limits are 1–50. Reads return up to 20,000 characters per call; use the
returned `next_offset` verbatim (UTF-16 units after LF normalization). Search
returns a `read_offset` to jump to the excerpt. `timestamp` is capture time if
present; `exported_at` is modification time, which can change during resync.

Only known top-level export files and one level of `.md` files under the capture
folders are read. Hidden files, nested folders, symlinks, hard links,
media, and arbitrary paths are excluded from text retrieval. Documents above 2 MiB are rejected;
scans stop at 10,000 directory entries or 64 MiB of document bytes. Scan
warnings identify incomplete results; `partial: true` is not a zero-match claim.
The filesystem checks reduce accidental disclosure; this process runs as the
local user and is not an OS sandbox against hostile concurrent filesystem changes.

## Collecting and analyzing evidence

`collect` is the general primitive for agents. Natural-language interpretation
and summaries stay with the requesting agent. It can combine time, type,
keywords, quoted phrases, saved Themes, and pinning, then read full evidence:

```bash
# All calls with a person; paginate and read each call to summarize them.
node integrations/brain/cli.mjs collect '{"kinds":["meetings"],"participants":["Jared"]}'

# Evidence for themes across calls and screenshots in a specific local week.
node integrations/brain/cli.mjs collect '{"kinds":["meetings","screenshots"],"after":"2026-09-07T00:00:00-04:00","before":"2026-09-14T00:00:00-04:00"}'

# Synonyms or descriptive text; match=all is the default.
node integrations/brain/cli.mjs collect '{"kinds":["screenshots","notes"],"query":"pricing subscription renewal","match":"any"}'

# Complete task evidence for pattern analysis, or saved app Themes.
node integrations/brain/cli.mjs collect '{"kinds":["tasks"],"state":"all"}'
node integrations/brain/cli.mjs collect '{"kinds":["themes"]}'
```

Date bounds are `[after,before)` and require timezone offsets. Resolve relative
dates in the user's timezone; `status` reports the Mac's timezone and current
time as a default. Dates mean original capture/task creation time;
a saved Theme uses its latest member time. For tasks, choose
`date_field: task_completed` or `task_due` to filter completion or due dates. File modification times never
establish time-based relationships. Undated items are reported separately.

For the common “screenshots from the Jared demo” request, use `screenshots` with
`meeting: "Jared demo"`. The tool resolves the call and collects its screenshots
in one request. For precise participant selection, first use `meetings` with
`participants: ["Jared","Zoe"]` and optional topic/date filters. Resolve a
singular ambiguous call from returned titles/dates. Then call `collect` with
`kinds: ["screenshots"]` and `during: "<returned meeting path>"`; the same
operation can collect notes, dictation, or other captures during that interval.
`meeting_screenshots` is a convenience tool. These use the entire recorded
interval, not a short nearby window, and return original screenshot paths.
Missing end times are errors. Time overlap does not prove shared subject matter.

Every collection has `total`, `next_offset`, coverage, and scan warnings. Follow
all pages for “all”; read full documents, not just the 600-character previews,
before comprehensive analysis. `snapshot` identifies the app catalog: restart
pagination if it changes. Collections are sorted newest first, with stable path
ties; meeting screenshots are chronological. Keyword retrieval is lexical,
including OCR, not semantic or visual matching. For visual descriptions, use
`image` on relevant candidates. MCP returns actual image content; the CLI returns
base64 JSON. Original PNGs are limited to 8 MiB/100 megapixels, must be regular
unlinked files, and must appear in the app catalog. Markdown media links alone
cannot authorize reads. Missing originals are explicit errors.

`themes` contains saved app Themes and member source paths. An agent can also
infer recurring patterns from any collection, including tasks; those are its
analysis and do not create or alter saved app Themes.

The app catalog is an atomic metadata snapshot capped at 8 MiB by the companion.
It excludes captures hidden from search and replaces the capped legacy task
checklist with individual task documents containing notes and dates. It includes
all non-archived tasks. The companion rejects reads of captures absent from the
catalog, even if a stale markdown file remains. A broken catalog is an error,
never a reason to fall back to excluded files. Existing user-owned files and git
history are not a secure erase boundary. Migration v17 adds capture context to the app database; the companion still reads only exports.

## Visual metadata

Screenshots are primary sources when the task concerns a design, slide, screen,
or visual reference. OCR helps find candidates; it cannot establish layout or
colors. The markdown frontmatter contains full `ocr_text` as a YAML literal,
with a short description in the body. Titles prefer prominent OCR headings
instead of search/navigation text and preserve explicit user titles.

Screenshot `meetings` links distinguish `recorded_during` from historical
`time_overlap`. Meeting notes include the reverse `screenshots` list. Neither
association establishes that the image is about that call. UTC capture times
have `captured_local`, `timezone`/`tz`, and `timezone_source`: `capture` for a
saved capture timezone, or `export_mac` for older records. The latter is a
convenience conversion, not a claim about historical location.

Optional app/window/browser URL metadata is controlled in Settings → Library.
It is collected only for the selected window during intentional screenshots.
App exclusions and disabling the option remove saved window details. Browser
URLs require existing Accessibility access and browser support; query strings,
fragments, and userinfo are omitted. Old app/window details are not reconstructed.
`items_without_app_metadata` reports gaps in app-filtered queries.

Tags (`slide-deck`, `web-app`, `email`, `document`, `code`) carry heuristic scores,
not calibrated probabilities. `contains_pii` and `contains_confidential` are
`likely`, `not_detected`, or `unknown`. They can help identify material to review;
they are not permission to disclose/reuse content, and absence of a hint is not
proof of safety. `similar_to` and `sequence_id` identify visual near-duplicates
within two minutes, without changing or deleting originals.

The 400px thumbnail path appears in frontmatter/catalog. Explicit `image` reads
with `size: thumbnail` return only current, owned PNG thumbnails (up to 1 MiB).
No thumbnail request silently falls back to a full original. Derived context
and current thumbnail exports are removed when the capture is deleted/hidden.

## Privacy and write behavior

The Brain MCP makes no network calls, writes no index/log/content cache, and
does not invoke capture commands. The separate app CLI can capture or mutate
items when explicitly requested and allowed by MyMan Settings → Agents. Your MCP client or Grok Bot can send returned
content, including explicitly requested images, to its model provider. Using this integration with a hosted model is
different from MyMan's built-in on-device processing.

Brain files sync from the app; changing them would not update MyMan's database.
Task results reflect the export; old Brain folders have capped task history.
Missing `tasks.md` is reported separately from an existing empty legacy task list.

## Verify and publish

```bash
npm test --prefix integrations/brain
npm run check-bundle --prefix integrations/brain
```

Tests use temporary synthetic exports, including SDK client/server calls over
stdio. They do not read your actual Brain. The [implementation plan](../../docs/brain-plugin-plan.md)
records the boundaries and release criteria. Automated tests do not establish
Grok Bot account access or marketplace approval.

The root marketplace candidate is plugin version **0.4.1**, using the unchanged
0.4.0 companion shipped in MyMan 1.1.60. The [smoke results](../../docs/grok-bot-marketplace.md#verification-matrix)
record live Mac retrieval and official MCP SDK checks; Cursor UI discovery and
Hugo local execution remain explicitly unverified. [Listing copy](../../docs/marketplace-submission.md)
is ready for the reviewer. The plugin is prepared for submission from this repository's root. After the
changes are published to the public repository and the target-client smoke
test passes, submit the repository URL at
[Cursor Marketplace](https://cursor.com/marketplace/publish). Describe the Mac
and Node prerequisites and local-execution requirement explicitly. Acceptance
and Grok Bot availability depend on marketplace review and supported components.

References: [Agent Plugins](https://agent-plugins.org/plugin-authors/mcp-servers),
[Cursor plugins](https://cursor.com/docs/plugins),
[Grok Bot local execution](https://cursor.com/docs/grok-bot/work).

## Open source contributions

MyMan is **Apache-2.0 open source**. Humans and agents, including GrokBot, are welcome to propose fixes and improvements through the [public repository](https://github.com/tommy-muckstack/myman). See the [contribution guide](https://github.com/tommy-muckstack/myman/blob/main/CONTRIBUTING.md) for setup, checks and the pull request process.
