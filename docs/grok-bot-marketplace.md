# GrokBot marketplace preparation

Status: packages and local workflow are prepared; **not submitted, listed, or verified inside Hugo/GrokBot**. The Mac-local CLI is the supported integration path. No hosted Brain or automatic cloud sync is introduced.

## Two packages, distinct execution locations

- Repository root `plugin.json`, `mcp.json`, `skills/myman-brain/`: portable Agent Plugin for a client running on the Mac. MCP is retrieval-only and points at the committed standalone server, so installation needs Node.js 22+ but no npm install.
- `integrations/grok-bot/`: a skill-only Agent Plugin for GrokBot. It deliberately has no MCP server to start on the cloud computer. Its skill runs the installed MyMan CLI through approved local-computer execution on the registered Mac.

Both manifests are checked against the official Agent Plugins 1.0.0 schemas. No manifest contains a maintainer path or credential. The source companion uses `npm ci --ignore-scripts --prefix integrations/brain` for development, testing and bundling.

## End-user setup

1. Install signed MyMan on the Mac; open it once to create the Brain/catalog and bundled tools.
2. Install Node.js 22+ on the same Mac. Run `/Applications/My Man.app/Contents/Resources/myman doctor --json` (quote the app path).
3. In MyMan Settings → Agents, enable only the capture/markup/recording/library capabilities needed. Grant OS Screen Recording/Microphone/Camera/Accessibility/Calendar permissions only as required by the workflow.
4. Enable the desired local-computer execution policy in GrokBot on that Mac; approve the requested commands. Install/load the skill package through the host's supported plugin flow.
5. Ask Hugo to select that registered Mac and run doctor, then retrieve a small known fixture or requested meeting. A cloud-shell success cannot substitute for this check.

GrokBot documents local execution under Settings → General → Agent, with per-command approval as the default. Marketplace and installed plugin controls are documented separately. These are host features, not permissions MyMan can grant. [GrokBot settings](https://docs.x.ai/grok-bot/settings-and-notifications), [local execution security](https://docs.x.ai/grok-bot/approvals-security-and-privacy).

## Submission materials

Name: **MyMan**

Short description: **Find your meeting notes and screenshots, then capture, annotate and record on your Mac when you ask.**

Listing body: MyMan connects your Mac capture tools and local memory to your agent. Find meetings, notes, tasks, screenshots and saved themes by people, dates and keywords, with source citations. Capture and mark up screenshots, record a screen demonstration, or create a note using MyMan's local CLI. Requires MyMan and Node.js 22+ on a registered Mac and approved local-computer execution. Capture and mutations require explicit MyMan Settings → Agents grants and macOS permissions. Brain retrieval is read-only. Data stays in your local Brain; your agent receives only the content it requests, which may be processed by its model provider. No cloud Brain hosting, automatic messaging, or general pointer control.

Source repository: https://github.com/tommy-muckstack/myman

GrokBot package directory: `integrations/grok-bot`

Local Mac MCP package directory: repository root

License: Apache-2.0. Plugin version: 0.4.0.

Cursor's documented submission flow is a public Git repository plus review through its publish form; it supports the Agent Plugins standard. That verifies the Cursor route, **not a GrokBot-specific submission API or a Mac-local MCP bridge**. [Cursor plugin reference](https://cursor.com/docs/reference/plugins), [submission form](https://cursor.com/marketplace/publish), [Agent Plugins schemas](https://agent-plugins.org/).

Grok Build's TUI marketplace documentation describes a different product and is not used as proof of GrokBot installation. Before submitting, verify that the target host can select the skill-only directory (or export that package as its own repository root). Do not submit the root local-MCP package as if its server runs on the user's Mac from a cloud host. No account login, publisher agreement, or marketplace submission has been performed by this change.

## Verification matrix

| Check | Status / evidence |
| --- | --- |
| Root and GrokBot manifests validate | Automated schema tests |
| Bundled local MCP initializes; list/status/collect/read/image | Official MCP client against fixtures; no mutation tools |
| Mac CLI resource/action parser and error contract | Automated fixture tests and native smoke evidence |
| Cursor local plugin discovery / Customize UI | Not run in a signed-in Cursor host |
| Hugo local Shell doctor / retrieval | Requires a live Hugo invocation selecting the registered Mac; not claimed |
| Hugo screenshot → annotate → attach | Local native workflow tested independently; host attachment and permissions not verified |
| Mac offline / local execution denied | Skill gives an explicit stop/report path; app-offline CLI error tested; actual GrokBot policy refusal not simulated as a success |
| GrokBot marketplace submission / install | Host submission requirements and approval remain unverified |
| Cloud-to-Mac stdio MCP bridge | Not supported/claimed by this package |

See [CLI reference](agent-cli.md), [parity matrix](agent-cli-parity.md), and [test evidence](verification/agent-cli-2026-09-12.md). Remaining host checks require the actual client/account; they are not reasons to upload private Brain data or enable an unrestricted network service.
