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
- Ambiguous requests show Search/Create choices; resolved requests use a small
  options menu in the input row. Both override automatic suggestions. A
  manual choice survives further typing until the field is cleared or `/` opens
  the command palette.
- The optional Apple on-device classifier proposes only `search`, `create`, or
  `unclear`. It cannot start captures, call tools, generate code, or save notes.
  Requests are debounced, limited to one inference at a time, and stale responses
  are ignored. If unavailable or unsuccessful, both manual choices remain usable.
- Return can save an explicitly requested creation, but a model-only Create
  suggestion cannot change Return into a save action. Capture always uses a
  labeled button. An explicit timer request starts with Return or Start; parsing
  alone does not start it. Timer controls have no Save/Copy row.
- Search reuses the capture library, filters, themes and keyboard navigation.
  `/` reveals app actions, tasks, calendar and tools without inserting the slash.
  Subsequent typing filters commands; Escape exits. `calculator` opens an editable
  calculator with the supplied SVG icon.

The tools currently support checklists, bounded arithmetic, percentages, compatible
length/weight/temperature conversions, time zones, bill splits and hex colors. Splits distribute
remainder cents without losing money. A limited recursive-descent parser evaluates
arithmetic; input is never executable code. This is not unrestricted UI generation.
Unsupported prose remains an editable note preview or a search choice.

Saving uses the existing NotesStore and Brain export. It creates a Markdown note;
it does not persist a live card. Timers use an absolute deadline, support pause and
resume, and survive panel dismissal or input changes. They require My Man to remain
running; completion is an app sound, not a scheduled system notification.

## Reminders and countdown widget

`reminder in 10m for taking pizza out` and `remind me to take pizza out in 10 minutes`
prepare a message and deadline. `reminder` opens a compact title/date editor;
`remind me to call Sam tomorrow at 9am` supports an absolute local time. The Set
reminder button confirms the preview; typing or parsing never schedules an alert.

Reminders persist locally across restarts. With notification permission, macOS
schedules the alert even while My Man is closed. Without permission, the UI explains
that My Man must remain open. Due reminders remain in the widget until dismissed.

Starting a timer or setting a reminder shows one top-right countdown widget. Hover
or click expands it to timer controls and reminder messages; leaving collapses it.
Multiple activities share the widget, with the next deadline shown when collapsed.
The widget avoids the meeting recorder, does not take keyboard focus, and respects
Reduce Motion. Its fixed-size window is resized asynchronously outside layout.

## Compact results

Results measure their own height up to a 320pt scroll limit. Window resizing remains
deferred by the existing panel controller. Tasks and calendar use full-width inline
lists, small empty states, and a week selector; classic companion panels keep their
existing layouts. The muted microphone uses the supplied `micOff` SVG path.

`8am in Iceland` means today's 8am in Iceland expressed in the Mac's time zone.
`8am New York to Iceland` specifies both ends; `8am to Iceland` starts locally.
`time in Tokyo` converts the current instant. Both sides show dates to make day
rollovers clear. Region names and ET/PT use the macOS time-zone database; fixed
abbreviations such as PST/EST retain their literal offsets. IST means India and
CST means US Central Standard; city names avoid abbreviation ambiguity. Skipped
or repeated daylight-saving times ask for a different time or explicit UTC offset.
Unknown locations get a short example instead of falling through to unit conversion.

Hex colors produce four deterministic coordinating colors: a complementary accent,
softer neighboring shades, and a dark anchor. Near-neutrals use a muted blue family.
These are palette suggestions, not an accessibility contrast guarantee. Each swatch
copies its own hex code; the result's Copy/Save actions retain the entered base hex.

## Voice input

The listening footer says “Speak or type” and uses the meeting recorder’s waveform.

Only the enabled adaptive launcher's controller automatically starts listening,
after the panel is visible. It uses a raw session on `AudioCapture.shared`, avoiding
a second microphone engine or a new voice-processing request. Parakeet transcribes
utterances locally after a pause. The microphone pauses during transcription and
resumes afterward while the launcher remains open. Text is appended to the latest
input and never submitted automatically. Editing the input stops listening immediately
and rejects pending transcription. Programmatic speech updates do not stop listening.
Turning off the microphone explicitly persists a one-hour pause in UserDefaults
(`adaptiveListeningPausedUntil`). New panels respect that timestamp; automatic
listening resumes on the next opening after expiry. It never interrupts ongoing
typing when the hour expires. The mic button or General → Appearance → Reset can
clear the pause early. Closing the panel only stops its session; it does not snooze.

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

`QuickReminderTests` verifies natural-language messages, persistence, one-shot due
alerts, cancellation while notification permission is pending, and widget geometry.
