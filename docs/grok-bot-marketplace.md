# Cursor Marketplace and GrokBot preparation

Status (September 12, 2026): root Cursor candidate **0.4.1** is prepared and local retrieval is verified; **not submitted, listed, or verified inside Hugo/GrokBot**. The publish form requires sign-in in the available browser session. The Mac-local CLI is the supported integration path. No hosted Brain or automatic cloud sync is introduced.

## Two packages, distinct execution locations

- Repository root `plugin.json`, `mcp.json`, `skills/myman-brain/`: portable Agent Plugin for a client running on the Mac. MCP is retrieval-only and points at the committed standalone server, so installation needs Node.js 22+ but no npm install.
- `integrations/grok-bot/`: a skill-only Agent Plugin for GrokBot. It deliberately has no MCP server to start on the cloud computer. Its skill runs the installed MyMan CLI through approved local-computer execution on the registered Mac.

Cursor explicitly accepts the portable root Agent Plugins manifest, so `.cursor-plugin/plugin.json` is unnecessary for this single-plugin submission. Keeping one manifest avoids divergent metadata and MCP variable conventions. [Cursor supported formats and submission checklist](https://cursor.com/docs/reference/plugins).

Both manifests are checked against the official Agent Plugins 1.0.0 schemas. No manifest contains a maintainer path or credential. The source companion uses `npm ci --ignore-scripts --prefix integrations/brain` for development, testing and bundling.

## End-user setup

1. Install signed MyMan on the Mac; open it once to create the Brain/catalog and bundled tools.
2. Install Node.js 22+ on the same Mac. Run `/Applications/My Man.app/Contents/Resources/myman doctor --json` (quote the app path).
3. For optional app operations only, in MyMan Settings → Agents enable only the capture/markup/recording/library capabilities needed. Grant OS Screen Recording/Microphone/Camera/Accessibility/Calendar permissions only as required by the workflow.
4. Enable the desired local-computer execution policy in GrokBot on that Mac; approve the requested commands. Install/load the skill package through the host's supported plugin flow.
5. Ask Hugo to select that registered Mac and run doctor, then retrieve a small known fixture or requested meeting. A cloud-shell success cannot substitute for this check.

GrokBot documents local execution under Settings → General → Agent, with per-command approval as the default. Marketplace and installed plugin controls are documented separately. These are host features, not permissions MyMan can grant. [GrokBot settings](https://docs.x.ai/grok-bot/settings-and-notifications), [local execution security](https://docs.x.ai/grok-bot/approvals-security-and-privacy).

## Submission materials

For the root **myman-brain** Cursor candidate, use the [paste-ready listing and reviewer instructions](marketplace-submission.md). It describes the shipped CLI separately from read-only Brain MCP. The following listing describes the separate GrokBot skill package.

Name: **MyMan**

Short description: **Find your meeting notes and screenshots, then capture, annotate and record on your Mac when you ask.**

Listing body: MyMan connects your Mac capture tools and local memory to your agent. Find meetings, notes, tasks, screenshots and saved themes by people, dates and keywords, with source citations. Capture and mark up screenshots, record a screen demonstration, or create a note using MyMan's local CLI. Requires MyMan and Node.js 22+ on a registered Mac and approved local-computer execution. Capture and mutations require explicit MyMan Settings → Agents grants and macOS permissions. Brain retrieval is read-only. Data stays in your local Brain; your agent receives only the content it requests, which may be processed by its model provider. No cloud Brain hosting, automatic messaging, or general pointer control.

Source repository: https://github.com/tommy-muckstack/myman

GrokBot package directory: `integrations/grok-bot`

Local Mac MCP package directory: repository root

License: Apache-2.0. GrokBot skill package and root Cursor candidate: 0.4.1. Companion runtime: 0.4.0 (packaging/instruction update; no app rebuild required).

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
| Hugo local Shell status / recent with Mac machineId | **Not run**: no Hugo execution tool is available in this session; requires Hugo selecting the registered Mac |
| Actual Grok local-execution refusal / Mac offline | **Not run in Grok**: documented stop/report instructions and missing-root tests are not a live host-policy test |
| Submission | **Blocked on login**: actual browser visit to Cursor publish form shows “Sign in to apply”; nothing submitted |
| GrokBot listing / cloud-to-Mac stdio bridge | Not verified / not claimed; use Mac-local CLI execution |

To repeat local source checks (after the development npm install):

```sh
node integrations/brain/cli.mjs status
node integrations/brain/cli.mjs recent '{"kind":"meetings","limit":3}'
node integrations/brain/cli.mjs collect '{"query":"meeting","limit":3}'
npm test --prefix integrations/brain
npm run check-bundle --prefix integrations/brain
```

For Hugo, select the registered Mac and run `node "$HOME/MyManBrain/tools/cli.mjs" status`, then `node "$HOME/MyManBrain/tools/cli.mjs" recent '{"kind":"meetings","limit":3}'`. The file argument resolves to an absolute path on that Mac. If execution is unavailable, stop and report the limitation. A cloud empty-folder result does not answer a question about the user's Brain. The source checkout equivalent is `node /absolute/path/to/myman/integrations/brain/cli.mjs status` after the development install.

`node_modules/` is ignored. Fixture tests create synthetic temporary exports; no personal Brain content or live smoke payloads are committed. The marketplace change touches documentation, plugin metadata, skill instructions and MCP packaging tests only.

See [CLI reference](agent-cli.md), [parity matrix](agent-cli-parity.md), and [test evidence](verification/agent-cli-2026-09-12.md). Remaining host checks require the actual client/account; they are not reasons to upload private Brain data or enable an unrestricted network service.
