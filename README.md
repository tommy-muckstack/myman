<p align="center">
  <img src="assets/icon-256.png" width="128" alt="My Man icon" />
</p>

<h1 align="center">My Man</h1>

<p align="center"><b>The Mac sidekick: meetings, dictation, screenshots, and screen recording — all on-device, all in plain markdown you own.</b></p>

<p align="center">
  <a href="https://muckstack.com/download/myman">Download for Mac</a> ·
  <a href="#building-from-source">Build from source</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

---

My Man replaces a stack of subscription tools with one local app: meeting notes (Granola-style), voice dictation (Wispr-Flow-style), screenshots with a full editor (CleanShot-style), and screen recording (Loom-style). There is no backend, no account, and no cloud AI — transcription, OCR, translation, and summarization all run on-device.

Everything you capture lands in **`~/MyManBrain`** as plain markdown in a git repo: meetings with speaker-attributed transcripts, notes, screenshot OCR, recording transcripts, tasks, and the people you meet with. Point Claude (or any LLM) at the folder and it knows your work. Push the repo anywhere for backup. Your data is files, forever.

## Features

- **⌥Space launcher** — keyboard-first search with a Themes filter across screenshots/OCR, meeting transcripts and editable notes, dictation, notes, and recording transcripts/filenames. Exact matches appear first; typo and on-device semantic matches follow.
- **Themes & related captures** — conservative automatic groups from repeated titles, terminology and domains, with timelines, pinning, rename/merge and membership corrections. A small Related section connects existing documents.
- **Dictation** — hold Left ⌘, speak, release; text types into any app. On-device speech models, whisper-friendly, AI cleanup, a vocabulary that learns your proper nouns
- **Meetings** — detects Zoom / Meet / Teams / Webex / Slack huddles / Discord / FaceTime; starts listening 45s before calendar meetings but saves nothing without your explicit click; auto-stops on hang-up; named speakers, timestamps, slide snapshots, on-device summaries
- **Screenshots** — region capture, annotation editor (arrows, boxes, highlight, text, pixelate, crop, background removal), Photos-grade text selection, in-place translation
- **Screen recording** — drag any region (persistent frame outline), optional webcam bubble, mic + system audio, local `.mov` files; narration transcribed into the brain
- **Notes** — WYSIWYG markdown, instant capture

## Finding and remembering

Press **⌥Space** and type what you remember. Results show the matching passage
and its source; use **↑/↓**, **Return**, **⌘Y** to preview, or **⇧⌘C** to copy.
Quoted phrases stay exact. The funnel menu narrows results by type/date or opens Themes.
Conversational queries such as “Find the screenshot where the number was $49”
also recognize simple content/date constraints.

An empty search browses saved captures chronologically. Open the funnel menu to
browse **Themes** or filter by type, date, and pinning. Right-click to pin, rename,
assign/remove a Theme, hide from search, or delete. **Themes** appear after at
least three captures support a shared concept. They are collections
of captured material; correcting one does not create tasks or initiate work.

Screenshot search opens a text preview with highlighted OCR locations. Copy
all text, individual lines or nearby paragraphs; recognized links, email
addresses, phone numbers and dates have contextual actions. The editor’s
**Screenshot text & related captures** button opens the same surface, alongside
its existing Live Text selection tool. Edited screenshots clear their old text
and are recognized again in the background.

**Settings → Library** controls automatic Themes and local semantic search.
Existing captures are indexed incrementally after the database migration.
No app/window tracking or cloud inference is added. Deleting removes the
capture’s local index, vectors, OCR geometry and relationships plus its current
Brain export; Trash, earlier Git revisions and external backups can retain copies.

Architecture, migration decisions and verification are documented in the
[product audit](docs/product-architecture-audit.md) and
[implementation notes](docs/retrieval-implementation.md).

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
and [paste-ready listing copy](docs/marketplace-submission.md). Cursor/Hugo
client activation and marketplace acceptance are separate from local CLI/MCP
verification. Grok Bot must execute on the Mac containing the Brain.

On plugin updates, follow the [Cursor marketplace release policy](docs/cursor-marketplace-release.md); shipping the Mac app does not update the marketplace listing.

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
