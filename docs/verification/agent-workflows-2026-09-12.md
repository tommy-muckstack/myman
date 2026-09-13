# Agent workflow verification — September 12, 2026

Candidate: MyMan **1.1.62 (74)**; root/Grok packages and companion **0.6.0**. The action catalog now contains **62 native actions**. The ten Brain MCP tools remain retrieval-only.

## Automated verification

- Full native suite: **160 tests, six opt-in skips, zero failures**.
- Companion/CLI suite: **83 tests, zero failures**. Includes live catalog negotiation, clearly marked offline fallback, unsupported-action rejection before mutation, recovery across launch changes, command schemas and existing transport/retrieval checks.
- Font engine suite: **16 tests, zero failures**; TypeScript checking and bundle freshness pass.
- Five new native workflow tests cover receipt persistence/interruption/conflicts, redaction after deletion, fail-before-start for corrupt storage, bounded inline results, native exact/typo ranking and exclusions, and note-owned image copies with rollback on stale revisions.
- Both skills validate; generated companion and font bundles match source.

## Live isolated workflows

The debug preview used its own database, Brain, captures, receipt store and Unix socket. All content was synthetic. The only video source was the verification window, with microphone and system audio off. No real meetings or personal screenshots were used.

1. Live discovery returned the running preview's version and new actions; explicit offline discovery was marked unverified.
2. A screenshot was copied into a new note's owned assets; the saved Markdown referenced that copy.
3. Native search found the note from a misspelled query.
4. Font matching returned candidate names, distances, compared-character evidence, catalog size and a specimen, without claiming exact identity.
5. Font creation returned a valid `OTTO` OpenType file, captured/inferred coverage, provenance and specimen attachment. The specimen was visually inspected.
6. A custom specimen rendered from the saved `.otf` bytes.
7. A bounded window recording finalized and appeared in durable receipts.
8. After closing and relaunching the preview against the same synthetic library, job results recovered the original note/font IDs. Reusing the same request returned the existing note; changing its arguments returned `ID_CONFLICT`.
9. A recovered font receipt marked the old temporary preview expired; a fresh specimen regenerated from its saved font.
10. The finalized recording session survived restart; both result and stop returned the original recording.
11. Deleting the source screenshot preserved the note-owned image. Retained content receipts were redacted. Deleting the note removed its image copy.

The deletion harness initially expected a zero exit for a redacted job receipt; the CLI correctly returned a failure exit with `CONTENT_REMOVED`. After correcting that expectation, the cleanup checks passed. This was a harness expectation change, not a product workaround.

## Practical limits

- Font matching compares a limited bundled collection. It does not conclusively identify a page's original font or reconstruct unseen glyphs exactly. Coverage/provenance and specimen warnings remain part of the output.
- Native search uses the user's existing semantic preference and available local embeddings. Exact matches rank above meaning-based matches. It is bounded to 1,000 candidates and reports partial results; Brain MCP/export search stays lexical.
- Receipts retain up to seven days, 256 terminal jobs and 32 sessions, outside Brain. Inline results over 64 KiB are omitted with artifact references where available. Expiry/eviction ends deduplication; agents must not replay unknown work automatically.
- A crash between saving an artifact and persisting its completion can leave an interrupted receipt. That state requires inspection of existing captures. Recovery does not resume recording or run background tasks.
- Local attachment files and preview rendering were verified. Sending attachments through GrokBot/Cursor, live host skill activation and marketplace approval were not simulated or claimed.

Universal release build: `swift build -c release --arch arm64 --arch x86_64` passed for both architectures. The initial explicit scratch-path attempt failed to resolve cached AmplitudeCore; the normal release build path succeeded.
