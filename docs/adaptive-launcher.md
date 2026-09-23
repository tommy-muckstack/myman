# Adaptive launcher experiment

The `adaptiveLauncher` preference defaults to false. The existing launcher and
its task/calendar side panels remain the default. Enabling the setting replaces
the launcher with an input-first surface on the next opening; no migration,
default change, hosted API, classifier model download or new dependency is involved.

The classifier adds no model download. Auto-listening uses MyMan's existing
Parakeet speech engine, which may download its models on first use.

## Routing and controls

The interaction is inspired by [Shapeshift](https://github.com/anishfn/shapeshift),
whose cards combine intent classification with deterministic parsers. This
implementation uses native SwiftUI cards and MyMan's existing action closures.
It does not incorporate Shapeshift's source code or contact its hosted service.

- Retrieval prefixes take precedence over card keywords: `find my checklist`
  searches the existing capture index.
- Creation prefixes and recognized tool syntax open a preview. Plain topics,
  including bare numbers such as `2026`, offer Search/Create choices.
- Search/Create choices remain visible and override automatic suggestions. A
  manual choice survives further typing until the field is cleared or `/` opens
  the command palette.
- The optional Apple on-device classifier proposes only `search`, `create`, or
  `unclear`. It cannot start captures, call tools, generate code, or save notes.
  Requests are debounced, limited to one inference at a time, and stale responses
  are ignored. If unavailable or unsuccessful, both manual choices remain usable.
- Return can save an explicitly requested creation, but a model-only Create
  suggestion cannot change Return into a save action. Capture always uses a
  labeled button. Parsing a timer does not start it.
- Search reuses the capture library, filters, themes and keyboard navigation.
  `/` reveals app actions, tasks, calendar and tool examples.

The tools currently support checklists, bounded arithmetic, percentages, compatible
length/weight/temperature conversions, bill splits and hex colors. Splits distribute
remainder cents without losing money. A limited recursive-descent parser evaluates
arithmetic; input is never executable code. This is not unrestricted UI generation.
Unsupported prose remains an editable note preview or a search choice.

Saving uses the existing NotesStore and Brain export. It creates a Markdown note;
it does not persist a live card. Timers use an absolute deadline, support pause and
resume, and survive panel dismissal or input changes. They require My Man to remain
running; completion is an app sound, not a scheduled system notification.

## Voice input

Only the enabled adaptive launcher's controller automatically starts listening,
after the panel is visible. It uses a raw session on `AudioCapture.shared`, avoiding
a second microphone engine or a new voice-processing request. Parakeet transcribes
utterances locally after a pause. The microphone pauses during transcription and
resumes afterward while the launcher remains open. Text is appended to the latest
typed input and never submitted automatically. The microphone button can stop it.

The panel's dismissal callback explicitly stops capture; relying on SwiftUI
`onDisappear` alone would not cover retained AppKit panels. Generation checks
reject late permission, model-load, microphone-start and transcription callbacks.
Idle buffers are discarded every five seconds, and utterances are capped at twenty
seconds per slice. Audio remains in memory and is not saved as a capture. Permission
denial or model failure leaves typing available. Microphone input is an energy-based
endpoint detector, not speaker identification or wake-word detection.

## Local model options researched on 2026-09-23

- **Apple Foundation Models:** already used by MyMan, available offline with no
  inference charge. The model is proprietary and requires supported hardware,
  OS and Apple Intelligence availability. The experiment uses this existing path
  and keeps deterministic/manual behavior on other Macs.
  [Apple's framework announcement](https://www.apple.com/ca/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/)
- **local-jev:** MIT-licensed Jev-compatible local server with open model backends.
  Its author describes it as a research project. It needs a Python runtime and a
  separate weight download; the default Qwen configuration is substantially larger
  than a small app-specific classifier. It is a candidate for evaluation, not a
  bundled or benchmarked MyMan dependency.
  [Project and model licenses](https://github.com/amithgc/local-jev)
- **GLiClass:** Apache-2.0 classification library with local models. A selected
  checkpoint's license, macOS runtime integration, memory footprint and routing
  accuracy still need evaluation before adoption.
  [Project](https://github.com/Knowledgator/GLiClass)

Before selecting a downloadable model, measure search/create ambiguity, partial
input stability, cold/warm latency and memory on representative Macs. Public
benchmark scores do not establish accuracy for MyMan's routing task. The current
tests cover deterministic routing and behavior; Apple model classification quality
has not been benchmarked in this change.

## Verification

`swift test --filter AdaptiveLauncherTests` checks search precedence, ambiguous
topics, capture routing, arithmetic, conversions, cent allocation, checklist edits,
timer lifecycle and search through a synthetic in-memory capture library.

`swift test --filter AdaptiveLauncherVoiceTests` checks permission denial, late
startup cleanup, cancellation during preparation/transcription, resumed listening,
bounded silence buffers and preservation of typed input using injected audio
dependencies. These tests do not open a physical microphone.

`MYMAN_ADAPTIVE_UI_REVIEW=/tmp/myman-adaptive-review swift test --filter AdaptiveLauncherTests`
also renders native previews using synthetic input. The visual test is skipped
without the environment variable. It does not save notes or start recording.
