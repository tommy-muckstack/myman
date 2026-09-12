# MyMan Brain — Cursor Marketplace submission

Plugin: **myman-brain** · Candidate: **0.4.1** · Author: **MuckStack, LLC** · License: **Apache-2.0**

Repository to submit: https://github.com/tommy-muckstack/myman

Package directory: repository root. The nested `integrations/grok-bot` skill-only package is a separate integration, not the root Cursor listing.

## Short description

Search local MyMan meetings, notes, tasks, dictation and screenshot OCR with source citations. Read-only MCP, with optional consent-gated Mac CLI workflows.

## Listing body

MyMan Brain connects your agent to the information you intentionally capture with [My Man](https://muckstack.com/download/myman): meetings, notes, tasks, dictation, screenshots and recordings.

Find evidence by people, time periods, keywords and saved Themes. Read meeting transcripts with source paths and line numbers. Find screenshots from a meeting and explicitly retrieve thumbnails or originals when the task is about what something looked like.

The plugin includes a read-only local MCP server and an agent skill. The skill also explains how to use MyMan's separate Mac CLI for requested screenshot capture, markup, recording and note workflows. Those actions require the running app, explicit Settings → Agents grants and applicable macOS permissions; installing the plugin does not enable capture.

Requires MyMan on macOS and Node.js 22+ on that Mac. Open MyMan to generate the local Brain export and catalog. The plugin's committed MCP bundle needs no npm install. Existing exports remain readable while MyMan is closed.

The Brain MCP makes no network requests and never modifies MyMan's database. Brain sync is one-way from the app. Your agent/model provider can receive the excerpts and images it retrieves for your request. There is no hosted Brain, automatic upload, silent capture or cloud sync supplied by this plugin.

For Grok Bot, local-computer execution must target the Mac containing MyMan and its Brain. Installing a plugin on Grok's cloud computer does not give it access to the Mac's files. Live Hugo invocation and marketplace installation have not yet been verified.

## Reviewer setup

1. Install MyMan and open it. Node.js 22+ must be available to the local plugin process.
2. Clone the public repository and load its root Agent Plugin in Cursor. The portable `plugin.json`, `mcp.json` and `skills/` layout is [supported directly by Cursor](https://cursor.com/docs/reference/plugins).
3. For source CLI checks/tests, run `npm ci --ignore-scripts --prefix integrations/brain` from the checkout. This is a development requirement, not a requirement for the bundled MCP server.
4. Run `node integrations/brain/cli.mjs status`, then `node integrations/brain/cli.mjs recent '{"kind":"meetings","limit":3}'`.
5. Run `npm test --prefix integrations/brain` and `npm run check-bundle --prefix integrations/brain`. Tests use synthetic temporary data, never the reviewer's personal Brain.
6. In Cursor, invoke the `myman-brain` skill with “Find my three most recent meetings and cite the source paths.” Verify the ten `myman_brain_*` retrieval tools are available. Do not treat local fixture tests as evidence that this host check passed.

Keywords: myman, meetings, notes, macos, local, memory, transcripts, screenshots, dictation.

## Submission status

On September 12, 2026 the [publish form](https://cursor.com/marketplace/publish) displayed **Sign in to apply** in the available browser session. No submission was sent and no listing or approval is claimed. After signing in, submit the repository URL above using this copy; record the resulting submission confirmation separately.

See [smoke results and remaining client checks](grok-bot-marketplace.md#verification-matrix).
