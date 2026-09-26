<p align="center">
  <img src="assets/icon-256.png" width="128" alt="My Man icon" />
</p>

<h1 align="center">My Man</h1>

<p align="center"><b>The Mac sidekick for people and their AI agents: meetings, dictation, screenshots, and screen recording, all on-device, all in plain markdown you own. Claude, Grok Bot, and Cursor can use it through MCP or a JSON CLI.</b></p>

<p align="center">
  <a href="https://muckstack.com/download/myman">Download for Mac</a> ·
  <a href="#for-ai-agents-claude-grok-bot-cursor">Use with AI agents</a> ·
  <a href="#building-from-source">Build from source</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

---

My Man replaces a stack of subscription tools with one local app: meeting notes (Granola-style), voice dictation (Wispr-Flow-style), screenshots with a full editor (CleanShot-style), and screen recording (Loom-style). There is no backend, no account, and no cloud AI — transcription, OCR, translation, and summarization all run on-device.

Everything you capture lands in **`~/MyManBrain`** as plain markdown in a git repo: meetings with speaker-attributed transcripts, notes, screenshot OCR, recording transcripts, tasks, and the people you meet with. Point Claude (or any LLM) at the folder and it knows your work. Push the repo anywhere for backup. Your data is files, forever.

## For AI agents (Claude, Grok Bot, Cursor)

My Man gives an AI agent working on a Mac (or Linux) eyes, hands, and memory, all on the local machine:

| An agent can… | How |
| --- | --- |
| Search everything the user captured (meetings, notes, screenshots with OCR, dictation, recordings) with source citations | `myman-brain` MCP server (read-only) or `node ~/MyManBrain/tools/cli.mjs` |
| Take a screenshot of a display, region, or window and get the file path back | `myman screenshot --mode agent --json` |
| Annotate an image (arrows, boxes, highlights, text, blur) from a JSON list of operations | `myman annotate --id shot-ID --ops-file ops.json --json` |
| Record the screen, pause, resume, pull frames, and export a clip | `myman record start` / `stop` / `frames` / `export` |
| Start and stop meetings, dictation, notes, tasks, timers, and reminders | `myman meeting start`, `myman note create`, `myman actions` for the rest |
| Hand work between agents with briefs, leases, and reviewer sign-off | [Multi-agent workflows](docs/multi-agent-workflows.md) |
| Record a polished product demo (auto-zoom, smooth cursor, backgrounds, music, title cards) from a short script, on Linux today | `myman demo --script steps.json` ([Linux guide](docs/linux-agents.md)) |

There are 124 app actions in total. Every result is JSON with a stable error shape, every action has a strict schema (`myman actions`), and long work returns a job ID you can poll. It runs with no cloud relay, account, or API key.

**Permissions stay with the person.** Capture, markup, recording, and library access are separate grants in **Settings → Agents**, and they all start off. An agent can check what it's allowed to do with `myman doctor --json` or the `myman_app_capabilities` tool. It cannot turn grants on itself.

### Connect in about a minute

Install [My Man](https://muckstack.com/download/myman), open it once, and install Node.js 22 or newer. Opening the app writes both MCP servers to `~/MyManBrain/tools/`, so no clone or npm install is needed.

**Claude Code**

```sh
claude mcp add myman-brain -- node ~/MyManBrain/tools/server.mjs
claude mcp add myman-app -- node ~/MyManBrain/tools/app-server.mjs
```

**Claude Desktop, or any other local MCP client.** Add this to the client's MCP config (for Claude Desktop that's `~/Library/Application Support/Claude/claude_desktop_config.json`) and replace `YOUR_USERNAME`:

```json
{
  "mcpServers": {
    "myman-brain": { "command": "node", "args": ["/Users/YOUR_USERNAME/MyManBrain/tools/server.mjs"] },
    "myman-app": { "command": "node", "args": ["/Users/YOUR_USERNAME/MyManBrain/tools/app-server.mjs"] }
  }
}
```

**Cursor.** This repository is an [Agent Plugin](https://agent-plugins.org): `plugin.json`, `mcp.json`, and the [`myman-brain` skill](skills/myman-brain/SKILL.md) load both servers. See [local plugin setup](integrations/brain/README.md#use-with-a-local-mcp-client).

**Grok Bot.** Use local-computer execution on the Mac and call the CLI directly, for example `node ~/MyManBrain/tools/cli.mjs status`. The [Grok Bot setup prompt](integrations/brain/README.md#use-with-grok-bot) is ready to paste.

Then try one of these:

```sh
myman doctor --json                                   # what's ready and what's granted
node ~/MyManBrain/tools/cli.mjs meetings --participant Jordan --after 2026-09-01T00:00:00-04:00
myman screenshot --mode agent --display main --json   # returns the image path
```

If `myman` isn't on the PATH, it lives at `"/Applications/My Man.app/Contents/Resources/myman"`. The full reference is in [CLI setup, commands, and JSON contract](docs/agent-cli.md) and the [Mac and Linux capability matrix](docs/agent-cli-parity.md). A plain-text summary for language models is in [`llms.txt`](llms.txt).

### Questions agents and people ask

**Can Claude take a screenshot on my Mac?** Yes. With My Man installed and the capture grant on, Claude Code or Claude Desktop can call `myman screenshot` (or the `myman_app_screenshot_capture` tool) and get back the image file.

**Can an agent search my meeting transcripts?** Yes. The read-only `myman-brain` server searches meetings, notes, screenshots, dictation, and recordings by time, person, keyword, or topic, and it cites the source file for every result.

**Does anything leave my computer?** My Man itself runs its AI on-device and has no backend. An agent receives only the excerpts and images it asks for. Whether those then go to a hosted model depends on the agent you use.

**Can an agent record my screen without asking?** No. Recording is a separate grant that starts off, and macOS also asks for Screen Recording permission.

**Does it work on Linux?** Yes, for agents. A Node companion covers screenshots, annotation, notes, Brain search, recording, and polished demos on Ubuntu/X11 and Omarchy/Hyprland. See [Linux (agents)](#linux-agents).

**Is it free and open source?** Yes. It's Apache-2.0, and agents are welcome to open pull requests (see [AGENTS.md](AGENTS.md)).

## Features

- **⌥Space launcher** — keyboard-first search with a Themes filter across screenshots/OCR, meeting transcripts and editable notes, dictation, notes, and recording transcripts/filenames. Exact matches appear first; typo and on-device semantic matches follow.
- **Themes & related captures** — conservative automatic groups from repeated titles, terminology and domains, with timelines, pinning, rename/merge and membership corrections. A small Related section connects existing documents.
- **Dictation** — hold Left ⌘, speak, release; text types into any app. On-device speech models, whisper-friendly, AI cleanup, a vocabulary that learns your proper nouns
- **Meetings** — detects Zoom / Meet / Teams / Webex / Slack huddles / Discord / FaceTime; starts listening 45s before calendar meetings but saves nothing without your explicit click; auto-stops on hang-up; named speakers, timestamps, slide snapshots, on-device summaries
- **Screenshots** — region capture, annotation editor (arrows, boxes, highlight, text, pixelate, crop, background removal), Photos-grade text selection, in-place translation
- **Screen recording** — drag any region (persistent frame outline), optional webcam bubble, mic + system audio, local `.mov` files; narration transcribed into the brain
- **Notes** — WYSIWYG markdown, instant capture

Day-to-day details (launcher, search, notes, checklists, meeting transcripts) are in [Using My Man](docs/using-myman.md).

## Requirements

macOS 14.2+ (screen recording and translation need macOS 15+). Apple Silicon and Intel.

## Building from source

```bash
git clone https://github.com/tommy-muckstack/myman.git
cd myman
./scripts/run-dev.sh
```

`run-dev.sh` builds with SwiftPM, assembles a minimal `.app` bundle (macOS permission prompts require a real bundle with usage strings), signs it with your Developer ID if one is in your keychain (ad-hoc otherwise — expect repeated permission prompts across rebuilds), and launches it.

Plain `swift build` works for compile checks. Note: [FluidAudio](https://github.com/FluidInference/FluidAudio) is pinned to an exact version on purpose — do not bump it; later versions removed a model this app depends on.

Official releases are signed, notarized, and distributed only by the maintainer — building from source produces an unsigned local copy that cannot receive auto-updates.

## CLI and agent automation

Agents can use MyMan's tools through a local CLI, with structured results and
separate capture, markup, recording and library permissions in **Settings → Agents**.
These grants start off. macOS permissions still apply. The ordinary bare commands
and `myman://` URLs retain their existing interactive behavior.

```sh
"/Applications/My Man.app/Contents/Resources/myman" doctor --json
myman screenshot --mode agent --display main --region 0,0,1200,800 --json
myman annotate --id shot-ID --ops-file ops.json --clipboard --json
myman meeting start --title "Design review" --json
myman meeting stop --session-id RETURNED-ID --json
myman note create --title "Follow-ups" --body-file body.md --json
myman actions  # Complete schemas and required permissions, including fonts/tasks/themes
```

Requires Node.js 22+ on the Mac. The installed helper contains everything else;
no source checkout or npm installation is needed. See [setup, commands and
JSON contract](docs/agent-cli.md), [capability matrix](docs/agent-cli-parity.md),
and [GrokBot marketplace preparation](docs/grok-bot-marketplace.md).

## My Man Brain plugin

The optional [Brain plugin](integrations/brain/README.md) lets agents collect
meetings, notes, complete tasks, dictation, screenshots, and saved Themes by
time period, people, keywords, and topic, with source citations. Agents can
read full evidence and explicitly inspect original screenshots.
It includes a local MCP server, a JSON CLI for Grok Bot's local execution, and
a packaged skill. Requires Node.js 22+ on the Mac; update and open MyMan to
export the complete catalog. Older Brain folders work with limited coverage.

```bash
npm ci --ignore-scripts --prefix integrations/brain
node integrations/brain/cli.mjs status
```

The `myman-brain` MCP server remains read-only. The separate `myman-app` MCP server exposes the same local app actions as the CLI, protected by Settings → Agents grants. Both run locally without a cloud relay. A hosted agent such
as Grok receives the excerpts and images you ask it to retrieve; this optional integration
is separate from MyMan's on-device AI. The root Agent Plugin is the Cursor
Marketplace candidate; Node 22+ is enough for its committed MCP bundle.
See [marketplace checks and remaining host tests](docs/grok-bot-marketplace.md)
and [paste-ready listing copy](docs/marketplace-submission.md). Cursor/GrokBot
client activation and marketplace acceptance are separate from local CLI/MCP
verification. Grok Bot must execute on the Mac containing the Brain.

On plugin updates, follow the [Cursor marketplace release policy](docs/cursor-marketplace-release.md); shipping the Mac app does not update the marketplace listing.

Each installation reads that user's own `~/MyManBrain`. The public repository
contains the app and companion source, not anyone's Brain data or credentials;
no maintainer account or connection to the maintainer's Mac is needed.

### Optional private voice replies (Chatterbox beta)

Open the launcher, use the search field, then choose **Chat β**. Text chat is
ephemeral. To hear local voice replies, run `./scripts/install-chatterbox.sh`
once and `./scripts/run-chatterbox.sh` while using Chat. The companion binds
only to `127.0.0.1`; no prompt, transcript, or API key is sent to a service.

### Release diagnostics

`scripts/build-direct.sh` uploads dSYMs for My Man and bundled Sparkle helpers
to Sentry when `MM_SENTRY_AUTH_TOKEN` is set in gitignored `secrets.env` (or
`SENTRY_AUTH_TOKEN` is provided in CI). Create a Sentry internal integration
token with `org:read` and `project:releases` scopes. Symbol-upload failures do
not block signing or publishing a release.

## Privacy

All AI runs on-device (speech models, Vision OCR, Apple Translation, Foundation Models). Captures are stored locally. Official builds send anonymous usage analytics and crash reports (counts, kinds, and durations — never your content) and check a static feed for updates. The analytics keys are injected at release-build time and are not in this repo, so builds from source send no telemetry at all.

## Acknowledgments

The meeting-capture architecture (CoreAudio process taps, diarization approach, meeting detection) is informed by the MIT-licensed [Muesli](https://github.com/Muesli-HQ/muesli) project. Built with [FluidAudio](https://github.com/FluidInference/FluidAudio), [GRDB](https://github.com/groue/GRDB.swift), [Sparkle](https://sparkle-project.org), [Amplitude](https://amplitude.com), and [Sentry](https://sentry.io).

## License

[Apache-2.0](LICENSE) © MuckStack, LLC

## Open source contributions

MyMan is **Apache-2.0 open source**. Humans and agents, including GrokBot, are welcome to propose fixes and improvements through the [public repository](https://github.com/tommy-muckstack/myman). See the [contribution guide](https://github.com/tommy-muckstack/myman/blob/main/CONTRIBUTING.md) for setup, checks and the pull request process.

### Working with multiple agents

MyMan can coordinate named agents through human-issued credentials, shared source bundles, revision guards, recording ownership and explicit handoffs. [Four example workflows and setup](docs/multi-agent-workflows.md). The agent host selects the Mac and schedules work; MyMan remains a deliberately invoked utility. These additions are in the 0.8.0 candidate and require the corresponding updated app.

### Recorded briefs and visual proof

The 0.9.0 agent candidate adds **Watch this bug and fix it** and **Turn this demo into a launch kit** workflows. Create a brief from a recording, assign a worker and independent reviewer, and return saved visual evidence for every acceptance criterion. The native workspace also exports selected results as a portable share page with a reusable starter prompt. [Setup, recipes and host verification](docs/visual-brief-workflows.md). Requires the corresponding updated app; 1.1.65 does not advertise brief actions. Public GrokBot template links and actual host dispatch/delivery remain to be verified.

## Human and agent workflows (1.1.67 / companion 0.10.0)

Workflows and Recovery brings connection checks, selected context handoff, source-backed meeting decisions, dictation delivery history and safe continuation into My Man. Scrolling capture and floating references join keyboard/VoiceOver capture controls and scalable interface text. [Workflow guide](https://github.com/tommy-muckstack/myman/blob/main/docs/human-agent-workflows.md).

Sharing is optional and explicit: selected content can be published through a configured private sharing service with server-enforced expiration/revocation. Agent publishing has a separate disabled-by-default permission. This does not upload or host the Brain. Recipient copies cannot be recalled. [Personal sharing setup](https://github.com/tommy-muckstack/myman/tree/main/integrations/share-service).

## Linux (agents)

A local Node 22+ companion for Ubuntu/X11 and Omarchy/Hyprland: screenshots, annotations, notes, Brain search, and permission-controlled MCP. The Swift Mac app is unchanged.

Download `myman-linux-x64.tar.gz` and its `.sha256` file from the same release, then:

```sh
sha256sum -c myman-linux-x64.tar.gz.sha256
tar -xzf myman-linux-x64.tar.gz
bash myman-linux-x64/scripts/install-linux.sh
export PATH="$HOME/.local/bin:$PATH"
# As the owner, enable local commands and capture in ~/.config/myman/agents.json (all grants start off).
myman screenshot --display main --json
```

The installer lists optional Ubuntu and Arch packages and never runs sudo. [Linux setup, permissions, annotations, Omarchy, Xvfb and MCP](docs/linux-agents.md).
