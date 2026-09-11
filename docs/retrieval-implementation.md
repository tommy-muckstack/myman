# Unified retrieval implementation

The September 11 architecture audit preceded these changes. The existing
capture tools and source tables remain authoritative; this adds a shared
retrieval layer rather than another note or recording store.

## Components

| Component | Role |
| --- | --- |
| `CaptureSchema` / migration v14 | Backfills five original tables into derived `captureItem`; source insert/update/delete triggers keep it current. Original text, dates, titles and paths are preserved. Legacy vectors are replaced by a chunk index. |
| `CaptureIndex`, `CaptureQuery` | Unified FTS5, literal punctuation and quoted phrases, prefix/fuzzy matching, local semantic search, type/date/theme/pin filters and simple conversational query normalization. Explicit filters take precedence. |
| `CaptureEnrichment` | Durable pending IDs, serial utility queue, eight-item batches, revision-checked idempotent writes, overlapping 900-character chunks, conservative titles and relationship refresh. |
| `OCRStore` | Vision lines and normalized boxes tied to the image version, conservative paragraph grouping, sequential backfill and post-edit invalidation/recognition. Scene labels remain searchable metadata. |
| `CaptureSignals`, `ThemeStore`, `RelatedItems` | Shared terminology/domain/temporal evidence; stable themes with at least three seed artifacts, title preference, duplicate suppression, retained manual corrections, related-item scoring. |
| `CaptureLifecycle` | Shared deletion/pinning/title/exclusion actions. Foreign keys and triggers cascade derived data; cached images/vectors and open document surfaces are cleared on user deletion. |
| `CaptureLibraryView`, `CaptureDetailView` | Search/History/Themes in the existing launcher, native preview and OCR locations/copy actions, related sections in notes, meetings and screenshot editing. |

## Relevance and responsiveness

Ranking uses separate tiers: exact titles, exact body/OCR/transcript/notes text,
lexical prefixes, spelling/theme context, then semantic meaning. Full-title
equality, pins, bounded previous opens and recency break ties. Meaning cannot
displace an exact match. Snippets identify the field that matched, including
editable meeting summaries and recording transcripts, which were previously
missing from universal FTS.

The UI debounces for 55 ms, publishes lexical results first, then merges expanded
matches. Cancellation and generation checks suppress obsolete results. The
semantic scan fetches vectors together and releases SQLite before arithmetic;
fuzzy comparisons also run outside the database queue. History is paginated,
thumbnails are decoded off the main thread with a bounded cache, and theme pairs
are joined on demand instead of materializing an N² table.

Themes deliberately use explainable local signals, not generated project plans.
Repeated meaningful titles receive more weight than incidental body phrases.
Automatic processing preserves renamed/pinned themes, manual assignments,
blocked memberships and dismissed clusters. Semantic retrieval uses the existing
macOS English sentence embedding model; text/OCR search continues when it is
unavailable or disabled. Theme inference currently uses lexical/domain evidence;
it does not require a language model.

## Data lifecycle

The migration runs transactionally and is tested from the previous v13 schema.
Non-corruption startup errors no longer silently replace an intact library with
a fresh database. Enrichment applies only to an existing, nonexcluded item at
the same revision. OCR writes also verify the source image version. One OCR
pipeline now owns recognition; the Brain exporter no longer races it with a
second independent recognition pass.

Editing/redacting a screenshot immediately invalidates OCR, generated labels,
chunks and inferred relationships, updates its current export, and schedules
recognition of the new pixels. Deletion cascades the unified FTS record, chunks,
OCR geometry, memberships, relationship edges, pending work and click history.
Existing source-table FTS triggers continue to handle their original indexes.
Export jobs check current source data before writing, so queued jobs cannot
recreate deleted exports. The app does not promise secure erasure from Trash,
earlier Brain Git history, or user-managed backups.

Search exclusions retain the original capture for intentional recovery through
History’s “Include hidden captures” option; they remove semantic chunks and
theme/relationship associations and are filtered from universal search and
launcher recents. The optional external Brain plugin has its own explicitly
invoked access boundary; hiding an item in the app does not erase exported files.

## Verification and practical scope

The complete Swift suite passed: **63 tests**, including 14 retrieval tests.
The final retrieval suite was rerun after theme-label refinements. Debug and
universal Apple Silicon/Intel release builds passed. Existing warnings in
Analytics, MeetingDetector and ScreenRecorder remain outside this change.

Automated tests use isolated databases and synthetic media, covering v13→v14
migration/re-entry, all five source types, recording filenames, meeting notes,
exact/prefix/phrase/typo/semantic ordering, filtering, natural query constraints,
edits/deletion/FTS integrity, theme correction/merge/dismiss, OCR geometry and
paragraph grouping. Native SwiftUI search, themes and screenshot preview are
rendered for visual inspection. A 5,000-capture lexical benchmark measured
32–44 ms across verification runs on the development Mac; this is a fixture measurement, not a latency
guarantee for all libraries.

The changes use existing saved screenshots and text/transcript metadata. They do
not sample recording frames, monitor foreground apps/windows, or extract new
screenshots from meeting slides. Structured OCR actions use macOS data detection;
arbitrary code/tracking-number interpretation is left to ordinary region/text
copying. Larger libraries still use a local linear vector scan and conservative
theme inference, not an external vector service.

Compilation and fixture verification do not exercise live microphone, calendar,
screen-capture permission flows, or distribution signing/notarization. Those
existing capture workflows require a manual smoke check in a bundled app before
publishing a release.
