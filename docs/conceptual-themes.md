# Conceptual Themes

Themes previously promoted repeated OCR n-grams directly into groups. Names,
navigation labels, and fragments could win without sharing a meaningful subject.
The replacement extends the existing captureTheme/captureThemeMember model.

- Clean source evidence using known people, on-device named-entity recognition,
  and repeated interface-text filtering. Use meeting summaries when available.
- Group by sentence embeddings plus weighted lexical evidence. Compare several
  anchors to avoid single-item bridges; require three distinct captures.
- Ask the on-device language model to describe the shared activity or concept,
  identify supporting samples, and reject incoherent groups. Labels must be
  grounded, bounded, and more useful than a name or isolated phrase.
- Show a short explanation beneath each theme. Search matches explanations as
  well as titles; the existing Brain theme export includes the explanation.
- Preserve stable IDs through membership overlap or concept identity. Preserve
  renamed/pinned titles, manual assignments, removals, merges, and dismissals.
  Retire uncorrected legacy word clusters after a successful conceptual pass.
- On systems without an available local language model, only repeated useful
  explicit titles can form new themes. Existing conceptual themes are retained.
  Model failures do not erase existing themes.

Processing is serial and separate from capture indexing. It waits while audio
capture/transcription or meeting-note generation is busy. Unchanged source
snapshots skip inference; content-keyed vectors and group labels are cached.
Persisted group fingerprints reuse unchanged labels across app launches. Writes
recheck the source snapshot and preference, so edits/deletions/exclusions during
inference cannot resurrect stale evidence. No source text is sent to a server.

Migration v16 adds description and conceptDigest columns with empty defaults.
No original capture data is rewritten. Existing deletion cascades still own
memberships; manual corrections are read inside the final write transaction.

Validation includes synthetic semantic grouping, duplicate/noise rejection,
label grounding, legacy conversion, correction preservation, deletion/exclusion,
model-unavailable/failure behavior, migration idempotency, native UI rendering,
and the existing full test suite. An opt-in quality test accepts a private
SQLite backup under /private/tmp and writes its report outside the repository;
source material is never committed or logged by production inference.
