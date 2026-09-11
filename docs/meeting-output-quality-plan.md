# Meeting output: evidence, listening, and source preservation

The September comparison exposed four implementation defects: speaker/timestamp validation checked independent sets, long audio slices were joined into unbounded turns, microphone echo could be labeled as the owner, and Tasks used a separate permissive extraction pass. This work extends the existing local capture, notes, people, vocabulary, and task models.

1. Preserve original transcripts; store capture kind and calendar identities. Detect listening from channel evidence, remove cross-channel duplicates, and retain bounded timestamped utterances. Never infer podcast host/guest roles from microphone routing.
2. Ground derived facts and commitments in specific source turns and verbatim evidence. Resolve the owner explicitly, omit private passages before generation, keep unknown speakers out of assigned actions, and render listening captures as attributed takeaways.
3. Generate meeting tasks only from validated owner commitments. Archive old generated fragments reversibly, preserve manual/dictated tasks, and deduplicate within and across batches.
4. Propose recurring vocabulary for one-click acceptance. Apply approved corrections to derived text with an audit trail, preserving source wording. Enrich calendar identities and let users hide people.
5. Validate with synthetic regression fixtures and the two user-provided captures in a private working copy. Keep personal transcripts, recordings, comparison notes, and repair reports out of GitHub. Apply reviewed repairs with backups and conditional database updates.

Quality takes precedence over an arbitrary action count: if the recording does not support a commitment, omit it. Existing transcripts cannot acquire precise new word timestamps merely by splitting text; repaired legacy paragraphs must retain source anchors or explicitly identify estimated timing. New captures retain their actual audio-slice timestamps.

Validation completed on both private source recordings: the conversation retained
94 substantive source turns, 10 grounded points, and one supported email-sharing
commitment; its confidence was below the automatic-task threshold. The listening
recording retained 270 bounded turns and 10 attributed takeaways, with zero action
items and no owner/“You” attribution. The final local notes pass took about 256
seconds for both recordings together, using cached transcription. A smaller
extraction pass was faster but lost useful detail, so the four-fact pass was kept.
Reviewed repair proposals and original backups remain private; validation did not
overwrite the user's live database or exports.

The full native suite passed (111 tests, two opt-in tests skipped), as did the
opt-in source review and universal release build. Synthetic light/dark settings
captures are in `docs/screenshots/meeting-preferences-*.png`.
