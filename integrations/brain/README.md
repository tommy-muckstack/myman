# MyMan Brain plugin

Read-only search and retrieval for MyMan's exported meeting transcripts, notes,
tasks, people, recording transcripts, and screenshot OCR. The companion reads
`~/MyManBrain` and returns JSON with file paths, line citations, and pagination.
It does not open MyMan's database or change captures.

## Install on the Mac

Install Node.js **22 or later**, then clone this repository to a stable location
on the Mac that runs MyMan. From the repository root:

```bash
npm ci --ignore-scripts --prefix integrations/brain
node integrations/brain/cli.mjs status
node integrations/brain/cli.mjs recent '{"kind":"meetings","limit":5}'
node integrations/brain/cli.mjs tasks
```

Open MyMan at least once to create the Brain. A missing folder is an error,
not an empty knowledge base. The companion works while MyMan is closed, using
the last exported files. It is distributed from source separately from the
signed Mac app; no app rebuild is needed. Run `npm ci` again after updating.

For another export folder, pass `--root /absolute/path/to/MyManBrain` to the
CLI, or set `MYMAN_BRAIN_ROOT` in the process environment. The root must be a
real directory, not a symlink. Never configure your home directory as the root.

## Use with Grok Bot

Grok Bot's agent computer normally runs in the cloud. The companion and Brain
must be accessed through **Execution on Local Computer** on your Mac. The
desktop's existing execution policy applies. Node must be available to that
local process; use the absolute Node executable path if its PATH differs from
your interactive terminal.

Give Grok Bot this setup prompt after replacing the checkout path:

> MyMan is installed on my Mac, and its companion is at
> `/absolute/path/to/myman/integrations/brain/cli.mjs`. Use your local-computer
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
and `skills/`. After installing dependencies, a compatible local client can load
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
      "args": ["/absolute/path/to/myman/integrations/brain/server.mjs"]
    }
  }
}
```

Use an absolute path for Node too if required by the client's environment. A
remote/cloud client cannot see the Mac's files merely by loading this config.
There is no HTTP listener, tunnel, hosted connector, account, or OAuth flow in
this version.

## Tools and command equivalents

| MCP tool | CLI command | Arguments |
| --- | --- | --- |
| `myman_brain_status` | `status` | none |
| `myman_brain_search` | `search` | `query`, optional `kind`, `limit` |
| `myman_brain_recent` | `recent` | optional `kind`, `limit`, `offset` |
| `myman_brain_read` | `read` | `path`, optional `offset`, `max_chars` |
| `myman_brain_tasks` | `tasks` | optional `state`: `open`/`done`/`all`, `limit`, `offset` |

Kinds: `meetings`, `notes`, `recordings`, `screenshots`, `tasks`, `people`,
`vocabulary`. Searches are case-insensitive and require all keyword terms.
Result limits are 1–50. Reads return up to 20,000 characters per call; use the
returned `next_offset` verbatim (UTF-16 units after LF normalization). Search
returns a `read_offset` to jump to the excerpt. `timestamp` is capture time if
present; `exported_at` is modification time, which can change during resync.

Only known top-level export files and one level of `.md` files under the four
capture folders are read. Hidden files, nested folders, symlinks, hard links,
media, and arbitrary paths are excluded. Documents above 2 MiB are rejected;
scans stop at 10,000 directory entries or 64 MiB of document bytes. Scan
warnings identify incomplete results; `partial: true` is not a zero-match claim.
The filesystem checks reduce accidental disclosure; this process runs as the
local user and is not an OS sandbox against hostile concurrent filesystem changes.

## Privacy and write behavior

The companion makes no network calls, writes no index/log/content cache, and
does not invoke capture commands. Your MCP client or Grok Bot can send returned
content to its model provider. Using this integration with a hosted model is
different from MyMan's built-in on-device processing.

Brain files sync from the app; changing them would not update MyMan's database.
Task results reflect the export, and completed task history is capped by the
app. Missing `tasks.md` is reported separately from an existing empty task list.

## Verify and publish

```bash
npm test --prefix integrations/brain
```

Tests use temporary synthetic exports, including SDK client/server calls over
stdio. They do not read your actual Brain. The [implementation plan](../../docs/brain-plugin-plan.md)
records the boundaries and release criteria. Automated tests do not establish
Grok Bot account access or marketplace approval.

The plugin is prepared for submission from this repository's root. After the
changes are published to the public repository and the target-client smoke
test passes, submit the repository URL at
[Cursor Marketplace](https://cursor.com/marketplace/publish). Describe the Mac
and Node prerequisites and local-execution requirement explicitly. Acceptance
and Grok Bot availability depend on marketplace review and supported components.

References: [Agent Plugins](https://agent-plugins.org/plugin-authors/mcp-servers),
[Cursor plugins](https://cursor.com/docs/plugins),
[Grok Bot local execution](https://cursor.com/docs/grok-bot/work).
