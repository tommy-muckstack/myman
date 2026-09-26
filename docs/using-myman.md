# Using My Man

How the Mac app works day to day: the launcher, search, notes, checklists, updates during capture, and meeting transcript details. Agent setup is in the [README](../README.md#for-ai-agents-claude-grok-bot-cursor) and the [CLI reference](agent-cli.md).

### Finding and remembering

My Man opens with one input for search, tools and capture actions. This is the
standard launcher; no separate Adaptive setting is needed. Dark is the default,
with Light available in Settings. Explicit
“find…” requests search saved captures; “make…” requests preview a new note or
tool. Ambiguous text offers **Search existing** and **Create new**, and either
choice can override the suggested route. Screenshots and recordings start only
from a labeled action.
Hover Quick Tools to browse tools inline, or type `/` for the action list, tasks and calendar.
Schedule phrases work directly: `meetings today`, `what's on tomorrow`,
`meetings on Friday`, `this week's meetings`, `upcoming meetings`, and `what's next`.
The calendar shows evenly spaced dates and a day or week agenda, including all-day events.
`My open tasks` and `to-do list` open tasks. Explicit `find…` requests still search saved captures.

Type `calculator` for calculations, or `reminder in 10m for taking pizza out`
for a timed message. Timers and reminders share a small countdown widget that
expands on hover. Reminders can notify while My Man is closed when notifications
are allowed. Type `/` to browse and filter commands.

Opening the launcher starts local voice-to-text listening
after microphone permission and model readiness. Pause after speaking to append
words to the same field. Typing immediately stops listening and discards pending
speech. The microphone choice is persistent: mute stays muted, and turning it on
enables listening on future openings and when the input is cleared. Use the mic
button or **Settings → General → Launcher → Listen when the launcher opens** to
change it. Closing the launcher or typing stops only that listening session.
Complete spoken timer/reminder requests submit after the pause and close the launcher;
recordings still require a labeled action. It does not listen while the launcher is hidden. First use may download the existing Parakeet
speech model; recognition runs on-device.

Quick Tools recognizes checklists, timers, arithmetic, length/weight/temperature
conversions, time-zone conversions, bill splits and hex colors with four coordinating
swatches. Click a companion swatch to copy its hex. Results fit the panel; tasks and
calendar become full-width lists. Non-timer results can be copied or saved to Notes;
saved results are Markdown, not persistent interactive widgets. Several timers can run at once and stack in the top-right corner. A started timer
continues while My Man is running and rings, shakes, and pulses when it finishes until you dismiss it; the expanded widget has a bell toggle for sound. Timers do not
survive quitting the app. Simple requests use local rules; ambiguous phrasing may
use Apple's on-device Foundation Models on supported Macs with Apple Intelligence
enabled. No hosted classifier or API key is used. This is a bounded adaptive
interface, not an arbitrary mini-app generator. See the
[implementation and local-model options](adaptive-launcher.md).

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
[product audit](product-architecture-audit.md) and
[implementation notes](retrieval-implementation.md).

### Updating and stopping recordings

Update checks and downloads remain available during capture. Only installation
and restart wait for active work; completed dictation does not block them. A ready
update explains the actual activity, with **Cancel Recording…** for a live take
or unfinished screen selection. The app and menu-bar menus also offer cancellation.
Discarding a live take requires confirmation, including its meeting note when
applicable. Background transcription is identified separately from recording.

### Writing notes and checklists

Enter a new note title and press Return to open its document, with the cursor
ready on the next line. New notes opened from the library are saved as documents
before editing, and a failed save keeps the capture draft available.

Type `[]` or `[ ]` at the start of a body line to create a checkbox (also works
after a bullet). Click the box to check/uncheck it; completed text is struck
through, while the saved file uses ordinary `- [ ]` / `- [x]` Markdown. Return
continues the list with an unchecked item. Tab indents bullets and checkboxes by
32 points; Shift-Tab outdents. Nested levels, inline formatting, and explicit
strikethrough survive saving, reopening, and undo.

### Meeting reliability and transcript fidelity (2026-09-17)

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
