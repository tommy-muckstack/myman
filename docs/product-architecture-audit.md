# Man: architecture audit and implementation map

Audit completed before product changes, September 11, 2026. Existing plugin
work in this checkout is separate from the human-facing product changes.

## Existing product

| Area | Implementation and current behavior |
| --- | --- |
| Dictation | `VoiceController`, shared `AudioCapture`, FluidAudio transcription and cleanup; hold/release to paste, review/copy, history persisted in `dictation`. |
| Meetings | `MeetingController`, CoreAudio process taps, calendar/app detection, provisional recordings that are discarded unless retained (or explicit auto-record setting), serialized transcription, diarization, slide captures, local summaries. Editable title/summary/transcript in `MeetingDocumentView`. |
| Screenshots | `CaptureController` freezes displays, opens region picker, saves PNG/clipboard, shows thumbnail and editor. Vision OCR/classification runs after capture. |
| Screenshot manipulation | Existing annotation, crop, pixelation, background removal, image overlays, translation, and VisionKit Live Text selection/data detectors. Extend these instead of replacing them. |
| Screen recordings | `ScreenRecorder`, region selection, optional webcam/cursor effects, microphone/system audio, local MOV and narration transcript. |
| Notes | `Note`/`NotesStore`, quick capture and autosaving rich Markdown documents. |
| Other existing surfaces | Tasks/calendar side panels, people/vocabulary learning, a hidden local chat beta. These are not new organizational abstractions and will not become Themes. |

## Navigation, keyboard, and visual language

Menu-bar-only app, no regular Dock/main window. The launcher is a floating
nonactivating panel with search, capture action tiles, and hover recents.
Typing replaces tiles with up to eight results; arrows/Return select/open,
hover actions copy/delete. Notes, meetings, and screenshot editor have their
own document windows. Settings has General, Dictation, Shortcuts.

Default global shortcuts (user-remappable): Option-Space launcher,
Command-Shift-S screenshot, Option-Shift-N note, hold Right Option dictation,
Option-Shift-M meeting, Option-Shift-R screen recording. Carbon hotkeys do not
need Accessibility; the modifier monitor and paste flow use existing permission
handling. Preserve all these tool entrypoints.

`MM` tokens provide Outfit typography, semantic light/dark colors, spacing,
rounded utility surfaces and restrained accent. `FloatingPanel(fixedSize: true)`
is required for dynamic content; window sizing must be deferred out of layout.
Interactive targets use `.clickable()` with at least a 24-point hit area.

## Data, processing, and retrieval

`Database.shared` is a GRDB SQLite queue in Application Support/MyMan. Thirteen
incremental migrations currently define:

- `note`: id, title/body, created/updated, optional Float32 sentence embedding.
- `screenshot`: id, image path, OCR/classification text, created, embedding.
- `meeting`: id/title, start/end, audio paths, transcript, editable summary,
  JSON slide paths. There is no separate meeting-note object; summary is editable.
- `dictation`: id, dictated text, created date.
- `recording`: id, MOV path, duration, created date, transcript.
- `searchClick`: bounded local query/open log for ranking; task/person tables.

FTS5 indexes exist for notes (title/body), screenshots (OCR), meetings
(title/transcript), and dictation (text). Source-table triggers keep them in
sync. Recording search uses LIKE scans; meeting summaries aren't indexed.
Search currently queries each type independently and assigns coarse scores.
Click boosts can reorder tiers. It does not return match-field provenance or
position-aware snippets. Rows show mostly the start of content, not the match.

NaturalLanguage `NLEmbedding.sentenceEmbedding(.english)` supplies local vectors.
Only the first 1,000 characters of notes/screenshots are embedded. Search loads
the most recent 400 of each type and performs extra per-row vector queries.
No hosted embeddings, external vector database, or semantic coverage of meeting
transcripts/dictations/recordings. The decoded-vector cache uses a partial blob
fingerprint, which can return stale vectors after edits.

OCR text is saved as `screenshot.ocrText`. Vision can return normalized line
bounding boxes (`ImageAnalysis.TextObservation`), but these are recomputed in
the editor and not persisted. Saving an edited screenshot does not currently
refresh OCR, allowing redacted/cropped text to remain searchable.

Capture-critical work is separate from OCR/embedding/transcription tasks.
Meetings have a serialized transcription chain and recovery of orphaned audio.
There is no shared incremental enrichment queue or reusable relationship model.
No existing tags, collections, inferred topics, or content folders in SQLite;
the `AppTheme` type is appearance (light/dark), not content organization.

## Storage and lifecycle

All core capture and AI processing is local. Media paths live outside SQLite;
screenshots default to Pictures/My Man and are configurable. Brain exports are
plain Markdown in `~/MyManBrain`, automatically committed to a local Git repo.
Sync is one-way from app to exports. A user can push Git elsewhere manually;
the app has no content-sync backend. Official builds send analytics/crash data
and check for updates. The optional Brain plugin exposes chosen local excerpts
to an external client when invoked; it is not part of this retrieval UI.

Existing deletion is spread across launcher/notes/meeting paths. Most media is
trashed and current Brain exports are removed, but click history/cache cleanup
is incomplete. Git history can retain deleted exports; deleting a current file
does not erase a user's existing Git backups. Avoid promising secure erasure.
Async export/transcription tasks need guards so deletion cannot recreate items.

## Implementation sequence

1. Add a derived unified capture index over the existing five source tables,
   maintained transactionally by triggers. Preserve original source rows and
   titles. Store user pin/exclusion/title corrections in the shared abstraction.
2. Return exact/FTS results immediately; add fuzzy and local chunk-semantic
   matches afterward, with strict tiers, match provenance, snippets and filters.
3. Persist OCR lines and geometry, backfill incrementally, and refresh OCR after
   image edits. Extend the editor with text search/copy and matched locations.
4. Add a durable enrichment queue, reusable related-item scores and conservative
   Themes derived from repeated captured terminology/domains and similarity.
   Store manual corrections so automatic processing cannot undo them.
5. Integrate Search/History/Themes in the existing launcher and add a compact
   shared detail/Related surface reused by existing document windows.
6. Centralize deletion/exclusion and cascade indexes/chunks/OCR/relationships.
   Add controls for Themes, semantics, search exclusion and clearing history.
7. Verify migrations and behavior using isolated databases/fixtures, debug and
   universal release builds, then inspect rendered native UI where tooling allows.

Capture remains deliberate. No autonomous actions, new surveillance, unsolicited
suggestions, cloud inference, or project-management objects are introduced.
