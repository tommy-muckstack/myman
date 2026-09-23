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

An optional **Settings → General → Appearance → Adaptive launcher (experimental)**
starts My Man with one input field. It is **off by default**; the classic launcher
remains the default. Reopen the launcher after changing the setting. Explicit
“find…” requests search saved captures; “make…” requests preview a new note or
tool. Ambiguous text offers **Search existing** and **Create new**, and either
choice can override the suggested route. Screenshots and recordings start only
from a labeled action.
Type `/` for the action list, tasks, calendar and Quick Tools.

With Adaptive enabled, opening the launcher starts local voice-to-text listening
after microphone permission and model readiness. Pause after speaking to append
words to the same field. Typing immediately stops listening and discards pending
speech. Turning the mic off pauses automatic listening for one hour, including
across reopenings and restarts. Click it again or use **Settings → General →
Appearance → Reset** to resume early. Closing the launcher releases its microphone
session. When the pause expires, auto-listening resumes on the next opening. Dictation does not submit the request or start a recording. It does not
listen while the launcher is hidden. First use may download the existing Parakeet
speech model; recognition runs on-device.

Quick Tools recognizes checklists, timers, arithmetic, length/weight/temperature
conversions, time-zone conversions, bill splits and hex colors with four coordinating
swatches. Click a companion swatch to copy its hex. Results fit the panel; tasks and
calendar become full-width lists. Non-timer results can be copied or saved to Notes;
saved results are Markdown, not persistent interactive widgets. A started timer
continues while My Man is running and sounds when it finishes. Timers do not
survive quitting the app. Simple requests use local rules; ambiguous phrasing may
use Apple's on-device Foundation Models on supported Macs with Apple Intelligence
enabled. No hosted classifier or API key is used. This is a bounded adaptive
interface, not an arbitrary mini-app generator. See the
[implementation and local-model options](docs/adaptive-launcher.md).

Press **⌥Space** and type what you remember. Results show the matching passage
and its source; use **↑/↓**, **Return**, **⌘Y** to preview, or **⇧⌘C** to copy.
Quoted phrases stay exact. The funnel menu narrows results by type/date or opens Themes.
Conversational queries such as “Find the screenshot where the number was $49”
also recognize simple content/date constraints.

An empty search browses saved captures chronologically. Open the funnel menu to
browse **Themes** or filter by type, date, and pinning. Hover a capture row for
**Copy**, **Copy Path**, and **Delete**; the same controls appear on keyboard-selected
rows. Screenshots copy as images, recordings as files, and notes/meetings as text.
Copy Path uses the original media file or the note/meeting’s Markdown file in
MyManBrain. Deletion asks for confirmation. Right-click to pin, rename,
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

## Updating and stopping recordings

Update checks and downloads remain available during capture. Only installation
and restart wait for active work; completed dictation does not block them. A ready
update explains the actual activity, with **Cancel Recording…** for a live take
or unfinished screen selection. The app and menu-bar menus also offer cancellation.
Discarding a live take requires confirmation, including its meeting note when
applicable. Background transcription is identified separately from recording.

## Writing notes and checklists

Enter a new note title and press Return to open its document, with the cursor
ready on the next line. New notes opened from the library are saved as documents
before editing, and a failed save keeps the capture draft available.

Type `[]` or `[ ]` at the start of a body line to create a checkbox (also works
after a bullet). Click the box to check/uncheck it; completed text is struck
through, while the saved file uses ordinary `- [ ]` / `- [x]` Markdown. Return
continues the list with an unchecked item. Tab indents bullets and checkboxes by
32 points; Shift-Tab outdents. Nested levels, inline formatting, and explicit
strikethrough survive saving, reopening, and undo.

## Meeting reliability and transcript fidelity (2026-09-17)

Long live transcripts rebuild speaker hints and grouped rows in the background.
Name evidence uses literal matching instead of per-turn regular expressions;
participant refreshes are combined, and canceled refreshes cannot overwrite
newer edits or a stopped meeting.

Meeting transcription now checkpoints small audio slices during capture and resumes
from the saved offsets after interruption. Finalization uses Parakeet rather than
the stateful Qwen decoder implicated in a Core ML IOSurface exception. Automatic
retries stop after three persisted attempts; **Retry transcription**, **Regenerate
transcript**, and **Regenerate notes** keep failed recordings and prior content
available. Capture close saves `ended` immediately. Draft notes run asynchronously
and cache exact source windows; model deadlines fall back to extractive notes.

Meeting vocabulary no longer fuzzy-matches ordinary words against product/person
names. Only explicit spelling aliases are applied (for example, Shop Monkey →
Shopmonkey); the original recognition stays archived. Exports flag unmentioned
hotwords occurring at least three times and more than twice per 1,000 words in
`flagged_hotwords`, without rewriting those mentions.

An explicit `Owner <> Remote` title identifying the owner supplies two-person
speaker evidence. Exports include `status: transcribing` / `complete`,
`call_started_at`, `call_start_offset_seconds`, and `timestamp_origin:
recording_start`. Solo warm-up is omitted from the finished two-person transcript;
the original transcript retains it. Timestamps use recognizer word timing.

Notes include timestamp ranges, an overview of at most three sentences, verbatim
**Quotes**, and fixed **Next steps** with owners/dates or “None agreed.” `CI:`
interviews also extract questions and answers. `meetingInterviewKeywords` can
configure detection. An explicitly linked local `file://…md` prep file in the
calendar description supplies a conservative list of unmatched questions to
review; remote prep documents are not fetched automatically.

The screenshot selection dimension label now draws with a concrete Core Text font,
removing the NSString font-substitution path implicated in a nil-font exception.
Regression coverage includes retry exhaustion, crash checkpoints, late model
responses, concurrent edits, vocabulary bias, speaker identity, quotes and export
metadata. The opt-in `MeetingRecoveryIntegrationTests` reprocess a copied recording
and leave the live library untouched. Private recordings/transcripts are not test
fixtures in this repository.

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
