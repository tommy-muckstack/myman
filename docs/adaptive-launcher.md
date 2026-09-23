# My Man launcher

The input-first launcher is the standard experience from 1.1.96 onward. There is no Adaptive Launcher toggle; legacy values of `adaptiveLauncher` are ignored. Tasks and calendar open inline, and shortcut tiles retain quick access and recents. No hosted API, classifier model download or new dependency is involved. The app appearance defaults to Dark; Settings retains Light and preserves saved choices.

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
reminder button or Return confirms typed previews; typing or parsing never schedules an alert. A complete spoken timer/reminder request submits automatically after the pause. “Set a timer for thirty seconds to remind me to take a pizza out of the oven” creates a message reminder. Missing or invalid deadlines stay editable; a running timer is never silently replaced.

Reminders persist locally across restarts. With notification permission, macOS
schedules the alert even while My Man is closed. Without permission, My Man must remain open to deliver the alert. Due reminders remain in the widget until dismissed.

Starting a timer or setting a reminder shows one top-right countdown widget. Hover
or click expands it to timer controls and reminder messages; leaving collapses it.
Multiple activities share the widget, with the next deadline shown when collapsed.
Successful timer/reminder submission closes the center panel. The expanded widget has a bell toggle per activity: sound starts on, mute is retained while paused and for persisted reminders, and macOS notification sound is updated too. In-app completion uses a bundled chime through retained audio playback; scheduled notifications use the system notification sound. The widget avoids the meeting recorder, does not take keyboard focus, and respects
Reduce Motion. Its fixed-size window is resized asynchronously outside layout.

## Shortcut access

The empty input keeps the classic action tiles and hotkey hints beneath
it. Hovering a capture tile reveals its recent captures using the same library
view. Quick Tools hover/click expands all eight tools in that same panel; selecting one opens it inline. The visible slash hint is removed, while `/` still opens commands. Typing replaces the shortcut row with the relevant result.

## Agent access

Companion 0.11.0 exposes timer lifecycle, message reminders, calendar reads, and
side-effect-free tool evaluation through the live catalog, CLI, and app MCP.
Existing native grants apply; see [the CLI guide](agent-cli.md).

## Compact results

Results measure their own height up to a 320pt scroll limit. Window resizing remains
deferred by the existing panel controller. Tasks and calendar use full-width inline
lists, small empty states, and a week selector. The muted microphone uses the supplied `micOff` SVG path.

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

The input placeholder says “Speak or Type to Search or Create”. The meeting recorder’s waveform sits beside the microphone in the same accent color; listening has no separate footer.

The launcher's controller automatically starts listening,
after the panel is visible. It uses a raw session on `AudioCapture.shared`, avoiding
a second microphone engine or a new voice-processing request. Parakeet transcribes
utterances locally after a pause. The microphone stops at the first pause (about one second), transcribes that
request once, and stays off. The completed text is routed immediately to its result.
Spoken arithmetic such as “what’s one plus one” uses the local calculator.
Complete spoken timers and reminders submit once and close the launcher. Incomplete reminders, capture, and note saving still use their explicit controls. Editing the input stops listening immediately
and rejects pending transcription. Clearing the input resets it and starts listening again, unless the microphone is muted.
Turning off the microphone explicitly persists the choice in UserDefaults
(`launcherAutomaticListening`). It stays muted across reopenings and restarts until
the mic button or General → Launcher → Listen when the launcher opens enables it.
An active one-hour pause from an older release migrates to a persistent mute;
expired pauses migrate to enabled. Typing, finishing an utterance, and closing
the panel stop only the session and do not change this preference.

The panel's dismissal callback explicitly stops capture; relying on SwiftUI
`onDisappear` alone would not cover retained AppKit panels. Generation checks
reject late permission, model-load, microphone-start and transcription callbacks.
Idle buffers are discarded every five seconds, and utterances are capped at twenty
seconds per slice. Audio remains in memory and is not saved as a capture. Permission
denial or model failure leaves typing available. Microphone input is an energy-based
endpoint detector, not speaker identification or wake-word detection.

## Learning corrected words

Settings → Dictation → **Learn from my corrections** is off by default. When enabled,
correcting a small word or spelling within 45 seconds of dictation adds the settled
correction to the local `~/MyManBrain/vocabulary.md` dictionary. A short toast names
the word and offers Undo. Existing words are not added twice. Appending text, deleting
words, punctuation changes, and larger rewrites are ignored. This is a conservative
spelling heuristic, not a semantic guarantee; Undo and the editable dictionary remain
available for unwanted suggestions.

The Adaptive input tracks manual edits directly. Dictation into another app can learn
only after verified insertion into a readable Accessibility text field, while that same
field remains focused. Watching stops after 45 seconds, focus changes, a new delivery,
or disabling the setting. Only the dictated span is compared; keystroke contents and
surrounding text are not stored. Opaque editors that only support paste cannot learn
this way. Agent-originated dictation does not activate correction learning.

The dictionary is used by ordinary dictation and Adaptive voice requests. Learning
and correction stay on-device and require no additional service or subscription.

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
startup cleanup, cancellation during preparation/transcription, single-request listening,
bounded silence buffers and preservation of typed input using injected audio
dependencies. These tests do not open a physical microphone.

`MYMAN_ADAPTIVE_UI_REVIEW=/tmp/myman-adaptive-review swift test --filter AdaptiveLauncherTests`
also renders native previews using synthetic input. The visual test is skipped
without the environment variable. It does not save notes or start recording.

`QuickReminderTests` verifies natural-language messages, persistence, one-shot due
alerts, cancellation while notification permission is pending, and widget geometry.

When input is populated, a generous text-only **Clear** button replaces the microphone and Settings buttons. Clear restores the empty launcher and automatic listening, while respecting the saved microphone preference. Both `set timer for 5m` and `timer 5m` preview five minutes; Return starts the timer and dismisses the launcher.
The input always reserves the same leading icon space: Search by default, then the recognized tool/action icon. Recognition never moves the text horizontally.

The empty launcher has no Browse library button. Search is available through the input.

Reminder scheduling uses quick presets, a full calendar popover and a separate time control with editable hours/minutes, AM/PM and five-minute adjustments. The selected deadline stays visible; past times cannot be submitted. Local persistence completes before asynchronous macOS notification setup, so permission prompts do not trap the launcher on Setting. Dismissing a reminder invalidates pending notification callbacks. Scheduled reminders fall back to the app chime when notification sounds are disabled; mute suppresses both paths.
