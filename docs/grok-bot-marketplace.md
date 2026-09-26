> Candidate update, 2026-09-26: root plugin and Linux companion **0.13.0** add local Ubuntu/X11 capture, annotations, notes, portable Brain retrieval and permission-gated MCP. The unchanged Mac companion and GrokBot skill-only package remain **0.12.0**. Prepared, not submitted or marketplace-host-verified; the original Cursor application remains pending.

> Candidate update, 2026-09-23: root/Grok/companion **0.12.0** adds owned timer/reminder sound controls and sound state. Prepared, not submitted or host-verified. The original Cursor application remains pending; notify Cursor instead of filing another application.

> Candidate update, 2026-09-23: root/Grok/companion **0.11.0** adds local tool evaluation, timer/reminder controls, and calendar reads. Prepared; not submitted or host-verified. The prior publisher application remains awaiting review. Notify Cursor of the new candidate rather than filing a duplicate application.

> September 13, 2026: **0.10.0 candidate prepared** for connection checks, selected-file handoff, scrolling capture, meeting decisions, dictation recovery and optional expiring shares. A synthetic check through Grok Bot/Hugo reached the isolated My Man app on the Mac and returned a visible PNG, confirmed by Tommy's screenshot. This is host execution/attachment evidence, not marketplace approval or a public Bot template listing.


# Cursor Marketplace and GrokBot preparation

Status (September 13, 2026): root Cursor candidate **0.10.0** is prepared and local retrieval is verified. Tommy reports that the initial publisher application was submitted and is **awaiting review**; no listing approval or GrokBot activation is claimed. The 0.10.0 update has not been submitted or notified. The Mac-local CLI is the supported integration path. No hosted Brain or automatic cloud sync is introduced. Optional explicit publishing uses a separate private sharing service, a dedicated credential and a disabled-by-default sharing grant.

For each agent-package update, follow the [Cursor marketplace release policy](cursor-marketplace-release.md). Shipping MyMan does not update the marketplace package. Use the [My Man logo](https://raw.githubusercontent.com/tommy-muckstack/myman/main/assets/icon-256.png) in publisher/listing fields and check [submission status](marketplace-submission.md#submission-status) before preparing an update notification.

## Two packages, distinct execution locations

- Repository root `plugin.json`, `mcp.json`, `skills/myman-brain/`: portable Agent Plugin for a client running on the Mac or Linux host containing the Brain. Root 0.13.0 dispatches to the matching app MCP; Linux has the documented capture/library subset with all grants initially off. MCP includes separate read-only retrieval and permission-controlled app-action servers in committed standalone bundles, so installation needs Node.js 22+ but no npm install.
- `integrations/grok-bot/`: a skill-only Agent Plugin for GrokBot. It deliberately has no MCP server to start on the cloud computer. Its skill runs the installed MyMan CLI through approved local-computer execution on the registered Mac.

Cursor explicitly accepts the portable root Agent Plugins manifest, so `.cursor-plugin/plugin.json` is unnecessary for this single-plugin submission. Keeping one manifest avoids divergent metadata and MCP variable conventions. [Cursor supported formats and submission checklist](https://cursor.com/docs/reference/plugins).

Both manifests are checked against the official Agent Plugins 1.0.0 schemas. No manifest contains a maintainer path or credential. The source companion uses `npm ci --ignore-scripts --prefix integrations/brain` for development, testing and bundling.

## End-user setup

1. Install signed MyMan on the Mac; open it once to create the Brain/catalog and bundled tools.
2. Install Node.js 22+ on the same Mac. Run `/Applications/My Man.app/Contents/Resources/myman doctor --json` (quote the app path).
3. For optional app operations only, in MyMan Settings → Agents enable only the capture/markup/recording/library capabilities needed. Grant OS Screen Recording/Microphone/Camera/Accessibility/Calendar permissions only as required by the workflow.
4. Enable the desired local-computer execution policy in GrokBot on that Mac; approve the requested commands. Install/load the skill package through the host's supported plugin flow.
5. Ask GrokBot to select that registered Mac and run doctor, then retrieve a small known fixture or requested meeting. A cloud-shell success cannot substitute for this check.

GrokBot documents local execution under Settings → General → Agent, with per-command approval as the default. Marketplace and installed plugin controls are documented separately. These are host features, not permissions MyMan can grant. [GrokBot settings](https://docs.x.ai/grok-bot/settings-and-notifications), [local execution security](https://docs.x.ai/grok-bot/approvals-security-and-privacy).

## Submission materials

For the root **myman-brain** Cursor candidate, use the [paste-ready listing and reviewer instructions](marketplace-submission.md). It distinguishes read-only Brain MCP, local app-action MCP, and the GrokBot Mac CLI route. The following listing describes the separate GrokBot skill package.

Name: **MyMan**

Short description: **Find your meeting notes and screenshots, then capture, annotate and record on your Mac when you ask.**

Listing body: MyMan connects your Mac capture tools and local memory to your agent. Find meetings, notes, tasks, screenshots and saved themes by people, dates and keywords, with source citations. Capture and mark up screenshots, record a screen demonstration, or create a note using MyMan's local CLI. Requires MyMan and Node.js 22+ on a registered Mac and approved local-computer execution. Capture and mutations require explicit MyMan Settings → Agents grants and macOS permissions. Brain retrieval is read-only. Data stays in your local Brain; your agent receives only the content it requests, which may be processed by its model provider. No cloud Brain hosting, automatic messaging, or general pointer control.

Source repository: https://github.com/tommy-muckstack/myman

GrokBot package directory: `integrations/grok-bot`

Local Mac MCP package directory: repository root

License: Apache-2.0. GrokBot skill package, root Cursor candidate and companion runtime: 0.10.0. Recorded briefs require MyMan 1.1.66 or an app advertising the brief actions. See [current verification](verification/recorded-briefs-2026-09-13.md); the matrix below records the earlier marketplace baseline.

Cursor's documented submission flow is a public Git repository plus review through its publish form; it supports the Agent Plugins standard. That verifies the Cursor route, **not a GrokBot-specific submission API or a Mac-local MCP bridge**. [Cursor plugin reference](https://cursor.com/docs/reference/plugins), [submission form](https://cursor.com/marketplace/publish), [Agent Plugins schemas](https://agent-plugins.org/).

Grok Build's TUI marketplace documentation describes a different product and is not used as proof of GrokBot installation. Before submitting, verify that the target host can select the skill-only directory (or export that package as its own repository root). Do not submit the root local-MCP package as if its server runs on the user's Mac from a cloud host. No account login, publisher agreement, or marketplace submission has been performed by this change.

## Verification matrix

Executed September 12, 2026 on the development Mac. Only counts and validation outcomes are recorded here; personal titles, paths, OCR and transcripts are excluded from this repository.

| Check | Status / evidence |
| --- | --- |
| Public repository and description | Pass: public repository; description updated to explain Mac captures, Brain retrieval and CLI tools |
| Root and GrokBot manifests | Pass: official pinned Agent Plugins schema checks; package paths resolve within the repo |
| Clean dependency install | Pass: `npm ci --ignore-scripts --prefix integrations/brain`; no vulnerabilities reported |
| Companion fixture suite | Pass: **67/67**, no skips; source and committed bundle tested with official MCP SDK client |
| Bundle freshness | Pass: `npm run check-bundle --prefix integrations/brain` |
| Live `cli.mjs status` | Pass: `catalog_available: true` on the Mac's existing Brain |
| Live recent meetings, limit 3 | Pass: three results, each with a title and source path |
| Live keyword collect (`meeting`, limit 3) | Pass: three results with excerpts and `source.path`, `source.uri`, `source.start_line`, `source.end_line` citations |
| MCP startup/discovery/retrieval | Pass: official client initializes both entrypoints, lists exactly ten read-only tools, retrieves synthetic meeting/screenshot evidence and PNG images, rejects invalid paths |
| Install without npm dependencies | Pass: existing isolated bundled CLI/MCP test runs with no `node_modules` |
| Missing Brain failure | Pass: fixture test reports `BRAIN_NOT_FOUND`; skill tells cloud-only clients to report unavailable Mac access instead of copying Brain data |
| Cursor local link | Pass: candidate linked at `~/.cursor/plugins/local/myman-brain`; no existing link overwritten |
| Cursor Customize discovery / skill invocation | **Not verified**: link creation is not client activation. Cursor 3.4.20 is present; no authenticated IDE agent invocation was performed. Reload Cursor and run the reviewer prompt in the listing |
| GrokBot local Shell status / recent with Mac machineId | **Not run**: no GrokBot execution tool is available in this session; requires GrokBot selecting the registered Mac |
| Actual Grok local-execution refusal / Mac offline | **Not run in Grok**: documented stop/report instructions and missing-root tests are not a live host-policy test |
| Submission | **Awaiting review**: Tommy reports initial publisher application confirmation on September 12, 2026; this supersedes the earlier agent browser login blocker. Prepared package updates still require a separate notify/submit step |
| GrokBot listing / cloud-to-Mac stdio bridge | Not verified / not claimed; use Mac-local CLI execution |

To repeat local source checks (after the development npm install):

```sh
node integrations/brain/cli.mjs status
node integrations/brain/cli.mjs recent '{"kind":"meetings","limit":3}'
node integrations/brain/cli.mjs collect '{"query":"meeting","limit":3}'
npm test --prefix integrations/brain
npm run check-bundle --prefix integrations/brain
```

For GrokBot, select the registered Mac and run `node "$HOME/MyManBrain/tools/cli.mjs" status`, then `node "$HOME/MyManBrain/tools/cli.mjs" recent '{"kind":"meetings","limit":3}'`. The file argument resolves to an absolute path on that Mac. If execution is unavailable, stop and report the limitation. A cloud empty-folder result does not answer a question about the user's Brain. The source checkout equivalent is `node /absolute/path/to/myman/integrations/brain/cli.mjs status` after the development install.

`node_modules/` is ignored. Fixture tests create synthetic temporary exports; no personal Brain content or live smoke payloads are committed. The marketplace change touches documentation, plugin metadata, skill instructions and MCP packaging tests only.

See [CLI reference](agent-cli.md), [parity matrix](agent-cli-parity.md), and [test evidence](verification/agent-cli-2026-09-12.md). Remaining host checks require the actual client/account; they are not reasons to upload private Brain data or enable an unrestricted network service.

New workflow commands require MyMan 1.1.62: live action discovery, native fuzzy/semantic search, owned note-image attachments, font match/specimen results, and bounded job recovery. See [workflow recipes](agent-workflows.md). Font candidates are limited style comparisons, not verified original identities. The 0.8.0 marketplace update is prepared, not submitted or approved.

## Candidate 0.8.0 update

The root package now includes `myman-app`, a separate local action MCP server. The GrokBot package remains skill-only and uses approved execution on the registered Mac. New screenshot comparison, word-targeting, video finishing, readiness and font-quality commands require live app support (MyMan 1.1.65 or later). [New verification](verification/agent-v07-2026-09-12.md) supersedes the historical counts above. GrokBot invocation and attachment delivery remain unverified because no GrokBot execution tool is available in this environment.

Cursor update ready after publication: `myman-brain 0.8.0`, organization `@muckstack`, repository `https://github.com/tommy-muckstack/myman`. While the initial application is pending, send an authorized update to `marketplace-publishing@cursor.com`; do not file a duplicate application. No email/form is sent by this change.

### Multi-agent additions in candidate 0.8.0

Adds human-managed named credentials, explicit Mac verification, shared bundles of source references, guarded edits, session transfer, temporary resource reservations and pull-based handoffs/events. Each agent retains its own job ownership. There is no remote listener, automatic dispatch or message sending. Credentials scope bridge actions and do not sandbox same-login filesystem access. See [workflows and limitations](multi-agent-workflows.md). Local multi-client verification does not establish GrokBot host activation or cross-Mac delivery. This candidate is packaged with MyMan 1.1.65, but is not submitted to or approved by the marketplace; the initial Cursor application remains awaiting review. The next marketplace step is an authorized update email to marketplace-publishing@cursor.com with org @muckstack, repo https://github.com/tommy-muckstack/myman and version 0.8.0. No email or form was sent.

[Current 0.8.0 verification](verification/multi-agent-and-transparency-2026-09-12.md): 88 companion tests; native suite 177 tests with six existing skips; two live MCP clients and packaged CLI; Intel/Apple Silicon builds.

## Recorded brief candidate 0.9.0

Adds a native brief workspace; revisioned recording references; explicit worker/reviewer assignments; per-criterion evidence review; timestamped frame extraction with explicitly untimed transcripts; local share pages containing user-selected result media and separately authored public copy; two reusable workflow prompts; and live connection/setup checks. Requires an app advertising `brief.*` and `workflow.templates`; plugin installation alone does not supply native actions. See [workflow guide](visual-brief-workflows.md).

Cursor marketplace update ready: **myman-brain 0.9.0**. Repo: https://github.com/tommy-muckstack/myman. While the initial @muckstack application is pending, the next step is an authorized update email to marketplace-publishing@cursor.com with this version and repository, rather than a duplicate application. No email has been sent.

## 0.11.0 local verification — September 23, 2026

All 101 companion tests passed, including source/bundled MCP discovery and Unix transport. Bundle freshness passed. The 405-test native suite passed (33 optional tests skipped); 38 focused native tests with UI verification also passed. Timer ownership/session guards, reminder persistence, and permission/schema boundaries use synthetic fixtures. New timer/reminder workflows have not been run through a live GrokBot host. Root, Grok, and companion versions are 0.11.0; the prepared update has not been submitted.

## 0.12.0 local verification — September 23, 2026

All 105 companion tests passed, including sound-control CLI/schema discovery and Unix transport; bundle freshness passed after a clean dependency install. The 422-test native suite passed (29 optional tests skipped); all 27 focused native checks passed again after making the launcher standard. Native UI tests verified the spoken 30-second pizza reminder creates once, closes the launcher, and leaves the expandable widget visible; inline Quick Tools opens Calculator without another window. Sound controls cover ownership, persistence, pause/resume, and pending notification permission. Synthetic screenshots are in `docs/verification/*1.1.96.png`. Root, Grok, and companion candidates are 0.12.0; no live GrokBot host activation or marketplace submission is claimed.
