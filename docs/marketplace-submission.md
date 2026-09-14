> September 13, 2026: candidate **0.10.0** prepared. Synthetic Grok Bot local execution and visible image delivery passed; marketplace application remains pending.

# MyMan Brain — Cursor Marketplace submission

Plugin: **myman-brain** · Candidate: **0.9.0** · Author: **MuckStack, LLC** · License: **Apache-2.0**

Repository to submit: https://github.com/tommy-muckstack/myman

My Man logo for publisher/listing fields: https://raw.githubusercontent.com/tommy-muckstack/myman/main/assets/icon-256.png (use this icon, not the GitHub organization avatar).

On each plugin update, follow the [Cursor marketplace release policy](cursor-marketplace-release.md). App releases and marketplace updates are separate.

Package directory: repository root. The nested `integrations/grok-bot` skill-only package is a separate integration, not the root Cursor listing.

## Short description

Search local MyMan meetings, notes, tasks, dictation and screenshot OCR with source citations. Read-only retrieval plus permission-controlled local app tools through MCP or CLI.

## Listing body

MyMan Brain connects your agent to the information you intentionally capture with [My Man](https://muckstack.com/download/myman): meetings, notes, tasks, dictation, screenshots and recordings.

MyMan is **Apache-2.0 open source**. Humans and agents, including GrokBot, are welcome to contribute fixes and improvements through the [public repository](https://github.com/tommy-muckstack/myman). See the [contribution guide](https://github.com/tommy-muckstack/myman/blob/main/CONTRIBUTING.md) for the pull request process.

Find evidence by people, time periods, keywords and saved Themes. Read meeting transcripts with source paths and line numbers. Find screenshots from a meeting and explicitly retrieve thumbnails or originals when the task is about what something looked like.

The plugin includes a read-only retrieval MCP server, a separate app-action MCP server, and an agent skill. The app server and CLI share the same action catalog and permission checks for requested screenshot capture, comparison, markup, video editing, font workflows and notes. Those actions require the running app, explicit Settings → Agents grants and applicable macOS permissions; installing the plugin does not enable capture.

Requires MyMan on macOS and Node.js 22+ on that Mac. New text-targeted markup, window recording, pause/resume and video export commands require MyMan 1.1.61; discover available actions on the installed app before use. Open MyMan to generate the local Brain export and catalog. The plugin's committed MCP bundle needs no npm install. Existing exports remain readable while MyMan is closed.

The Brain MCP makes no network requests and never modifies MyMan's database. Brain sync is one-way from the app. Your agent/model provider can receive the excerpts and images it retrieves for your request. There is no hosted Brain, automatic upload, silent capture or cloud sync supplied by this plugin.

For Grok Bot, local-computer execution must target the Mac containing MyMan and its Brain. Installing a plugin on Grok's cloud computer does not give it access to the Mac's files. A synthetic Grok Bot/Hugo check on September 13 verified Mac-local execution and a visible returned PNG. Marketplace installation and public Bot template publication remain separate, unverified steps.

## Reviewer setup

1. Install MyMan and open it. Node.js 22+ must be available to the local plugin process.
2. Clone the public repository and load its root Agent Plugin in Cursor. The portable `plugin.json`, `mcp.json` and `skills/` layout is [supported directly by Cursor](https://cursor.com/docs/reference/plugins).
3. For source CLI checks/tests, run `npm ci --ignore-scripts --prefix integrations/brain` from the checkout. This is a development requirement, not a requirement for the bundled MCP server.
4. Run `node integrations/brain/cli.mjs status`, then `node integrations/brain/cli.mjs recent '{"kind":"meetings","limit":3}'`.
5. Run `npm test --prefix integrations/brain` and `npm run check-bundle --prefix integrations/brain`. Tests use synthetic temporary data, never the reviewer's personal Brain.
6. In Cursor, invoke the `myman-brain` skill with “Find my three most recent meetings and cite the source paths.” Verify the ten `myman_brain_*` retrieval tools are available. Do not treat local fixture tests as evidence that this host check passed.

Keywords: myman, meetings, notes, macos, local, memory, transcripts, screenshots, dictation.

## Submission status

**September 12, 2026 — initial publisher application submitted; awaiting review.** Tommy reports confirmation for MuckStack, LLC (`muckstack`) and this repository via the [publish form](https://cursor.com/marketplace/publish). This supersedes the earlier agent session's login blocker. No listing, approval or live GrokBot activation is claimed.

The first application used the GitHub organization avatar. Tommy chose to wait for review; use the My Man logo above in the next authorized update. A newly prepared candidate is not automatically submitted or accepted. While this application is pending, surface an update email to `marketplace-publishing@cursor.com` with `@muckstack`, the repository and candidate version rather than filing a duplicate application. No update email or second form submission is sent by this policy change.

See [smoke results and remaining client checks](grok-bot-marketplace.md#verification-matrix).

New workflow commands require MyMan 1.1.62: live action discovery, native fuzzy/semantic search, owned note-image attachments, font match/specimen results, and bounded job recovery. See [workflow recipes](agent-workflows.md). Font candidates are limited style comparisons, not verified original identities. The 0.8.0 marketplace update is prepared, not submitted or approved.

## Previous candidate 0.8.0

Adds a separate local app MCP server, screenshot differences, word-level OCR targets, timed video overlays/zoom/redaction, readiness waiting, and font-quality reports. New actions require an app build advertising them in live discovery; MyMan 1.1.65 includes them. See [verification](verification/agent-v07-2026-09-12.md). This candidate is packaged with MyMan 1.1.65, but is not submitted to or approved by the marketplace. The original publisher application remains awaiting review; no update email or duplicate form was sent.

### Multi-agent additions in candidate 0.8.0

Adds human-managed named credentials, explicit Mac verification, shared bundles of source references, guarded edits, session transfer, temporary resource reservations and pull-based handoffs/events. Each agent retains its own job ownership. There is no remote listener, automatic dispatch or message sending. Credentials scope bridge actions and do not sandbox same-login filesystem access. See [workflows and limitations](multi-agent-workflows.md). Local multi-client verification does not establish GrokBot host activation or cross-Mac delivery. This candidate is packaged with MyMan 1.1.65, but is not submitted to or approved by the marketplace; the initial Cursor application remains awaiting review. The next marketplace step is an authorized update email to marketplace-publishing@cursor.com with org @muckstack, repo https://github.com/tommy-muckstack/myman and version 0.8.0. No email or form was sent.

[Previous 0.8.0 verification](verification/multi-agent-and-transparency-2026-09-12.md): 88 companion tests; native suite 177 tests with six existing skips; two live MCP clients and packaged CLI; Intel/Apple Silicon builds.

## Recorded brief candidate 0.9.0

Adds a native brief workspace; revisioned recording references; explicit worker/reviewer assignments; per-criterion evidence review; timestamped frame extraction with explicitly untimed transcripts; local share pages containing user-selected result media and separately authored public copy; two reusable workflow prompts; and live connection/setup checks. Requires an app advertising `brief.*` and `workflow.templates`; plugin installation alone does not supply native actions. See [workflow guide](visual-brief-workflows.md).

Cursor marketplace update ready: **myman-brain 0.9.0**. Repo: https://github.com/tommy-muckstack/myman. While the initial @muckstack application is pending, the next step is an authorized update email to marketplace-publishing@cursor.com with this version and repository, rather than a duplicate application. No email has been sent.

## Human and agent workflow candidate 0.10.0

Adds guided Mac connection checks, selected-file context export, bounded scrolling capture, floating screenshot references, a human workflow activity view, cooperative cancellation for supported read/render jobs, source-backed meeting decision proposals, reviewed follow-up drafts, dictation delivery history/corrections and app-specific styles. My Man 1.1.67 or live discovery of the corresponding actions is required.

Optional sharing is a distinct, explicit network action. It uploads selected content to a configured personal HTTPS service backed by private storage. It requires a separate `sharing` grant plus confirmation; library access alone does not permit publishing. The server enforces expiry/revocation and never returns a bypass Blob URL. Prior downloaded copies cannot be recalled. The Brain retrieval server remains read-only and local.

Cursor marketplace update ready: **myman-brain 0.10.0**. Org **@muckstack**, repo https://github.com/tommy-muckstack/myman. While the initial application is pending, the next step is an authorized update email to marketplace-publishing@cursor.com, not a duplicate application. No email/form was sent. See [verification](verification/human-agent-workflows-2026-09-13.md).
