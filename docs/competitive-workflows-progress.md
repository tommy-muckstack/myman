# Competitive workflow implementation

Implementation of the [October 16 audit](competitive-product-audit-2026-10-16.md),
on `feat/competitive-workflows`. This is a review candidate, not a published app
or a claim that the competitive performance targets have been met.

## Implemented

- [x] Sentence-scoped spoken correction; quoted cues stay literal; original recognition remains in history.
- [x] Exact, nonrecursive snippets; pronunciation aliases; validated JSON import/export; opt-in nearby-field spelling context that remains in memory.
- [x] Voice editing of a selected field, named/custom transforms, focus/value/selection checks, guarded undo, and original-selection recovery.
- [x] Language and engine profiles, idle-boundary microphone switching, and local recognition/cleanup/delivery latency samples with median/p95.
- [x] Six meeting formats, custom instructions and reordered headings, exact typed-note preservation, explicit enhancement, and cache/commit revision checks.
- [x] Brain retrieval across full documents, meeting/theme/kind/date/mentioned-person scope, quoted source citations, coverage disclosure and saved recipes.
- [x] Human recording publication with direct private uploads, durable receipts, progress/cancel/retry, range playback, WebVTT, timestamp links, optional comments/reactions, expiry, revocation and cleanup.
- [x] Screen/region, selected-window and camera-only source picker, camera/microphone selection, and shared-mic narration.
- [x] Native workspace controls for titles, music, captions, timed redaction/zoom, rendered preview and saved edits.
- [x] Real recognizer timing sidecars, click-to-seek captions, correction, SRT/WebVTT, chapter markers, multiple cuts, undo, and reviewable gap/filler suggestions.

Voice editing defaults to **⌘⌥⇧V**; **⌘⌥⇧Z** undoes the last verified replacement
only while its field still matches. It requires Apple Intelligence on macOS 26+.
Snippets, aliases, transforms, language, engine and microphone settings are under
Voice. Secure fields are excluded from selection/context capture. Context is
opt-in; it is not saved in analytics or sent to hosted writing models.

In a meeting, choose **Format** or **Enhance my notes**. Typed notes retain their
exact text and remain separately attributed; generated facts still need
transcript evidence. A changed note/template invalidates an in-flight result.

Use **Ask this capture** or **Ask this theme**, or set filters inside Brain chat.
Person/company scope means a textual mention, not resolved speaker identity.
Retrieval is bounded and lexical. Citations validate verbatim quotes and source
IDs; this is not proof of every model inference or an exhaustive corpus audit.

The recording workspace preserves original media. Save edits separately; export
writes another uniquely named MP4 and caption sidecars, adds it to the library,
and offers **Share edited video**. Existing exports are never replaced. Cuts retime source events and captions.
A manually rewritten caption crossing a cut is omitted because its new words
have no reliable alignment. Recognition gaps require listening before removal;
they are not guaranteed silence. Chapter markers are spaced transcript markers,
not generated semantic chapters. Timed recording recognition uses Parakeet's
[supported languages](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3); the dictation profile does not change this engine.

Sharing is optional and needs the updated personal service. See
[setup, protocol and retention](../integrations/share-service/README.md). No
production deployment or upload was performed during this work. Anonymous
comments are opt-in per publication. Revocation blocks future reads, not copies
already downloaded or responses already in flight.

## Verification

Final check results are recorded below after the last source edits. Synthetic
fixtures contain no personal meetings, recordings or credentials.

- Universal release: the standard Apple Silicon + Intel build completed. No dependency pin, signature requirement or entitlement was weakened.
- Standard debug build: blocked by Xcode's inability to verify cached Sentry 9.7.0. Archive re-download was also blocked by DNS resolution in this environment. Sealed payload hashes matched; the specific certificate/signature failure is unresolved.
- Focused native regressions: **69 tests, five opt-in skips, zero failures**, including 12 new competitive-workflow tests and isolated native UI renders.
- Alternate native SwiftPM build: compiles the app and supports focused testing, but is not a substitute for standard Xcode artifact verification.
- Full native Swift suite: the first attempt stopped in an existing H.264 fixture. Excluding only codec-dependent exports ran 634 tests, with 45 skips and 78 failed assertions. Failures include unavailable clipboard/screen/audio/OCR services, locale-specific time-zone expectations and an attendee-name assertion. This broader run is **not green**.
- Actual new workspace export test: present, but blocked before rendering by AVFoundation `-11834` (H.264 encoder unavailable); existing movie export tests fail the same way. Do not infer working hardware export from timing-unit tests.
- Companion test run outside the sandbox: 153/155 passed; two person-only grant tests fail because Node cannot resolve the system user (`uv_os_get_passwd`, `ENOENT`). No grant checks were relaxed.
- Clean dependency refresh: offline cache lacked a pinned package and the network retry failed DNS. Companion dependencies were restored from a local checkout with identical lockfile dependency records and verified installed versions; the same 153/155 result was reproduced.
- Companion committed-bundle check: passed. Runtime companion sources/bundles did not change.
- Sharing service: 11 synthetic service tests pass. A 400 MiB metadata fixture is not a real large-file transfer; live pinned-SDK upload and browser playback still need verification.
- Native screen renders use the isolated verification harness. In-app browser automation was unavailable in this session.

## Native UI review

Synthetic screenshots, reviewed after rendering:

- [Scoped Brain chat](images/competitive-workflows/brain-chat.png)
- [Dictation profile and personalization](images/competitive-workflows/dictation-profile.png)
- [Recording source/device picker](images/competitive-workflows/recording-sources.png)
- [Transcript, captions and cuts](images/competitive-workflows/recording-timeline.png)

Reproduce the focused check with an isolated debug library:

```sh
MYMAN_VERIFICATION_ROOT=/private/tmp/man-verification-competitive-ui \
MYMAN_VERIFY_COMPETITIVE_UI=enabled \
swift test --build-system native \
  --filter 'CompetitiveWorkflow|DictationDelivery|MeetingProcessing|GroundedMeeting|HostedMeeting|AudioCaptureLifecycle|TranscriptionReview|AgentWorkflow'
npm test --prefix integrations/share-service
npm test --prefix integrations/brain
npm run check-bundle --prefix integrations/brain
```

`--build-system native` is an alternate compiler/test diagnostic path. The required
standard build/test and universal release commands remain those in `AGENTS.md`.

## Release gates

Release preparation on October 16 targets **1.1.113 (125)**. The standard debug
build still reports an unverifiable Sentry artifact outside the sandbox. The
release packaging attempt stopped before assembly because macOS reports **zero
valid signing identities**; a Developer ID Application certificate and its private
key must be accessible in the release session. No installer or update feed was
published. The sharing service's 11 tests and companion bundle check passed again.
Shell access to GitHub failed DNS; the connected GitHub app is available for
publishing the candidate branch and running clean CI.

- [ ] Standard debug build and test run with a verified Sentry artifact.
- [ ] Resolve/recheck the broader suite failures on a normal macOS desktop; distinguish baseline failures from any remaining regression.
- [ ] Real H.264 export, title/cut/caption timing and rendered redaction checks.
- [ ] Real microphone/device/camera transitions and verified text insertion/undo in representative editors.
- [ ] Warm/cold dictation benchmark on a declared reference Mac; the audit's p95 ≤1.5 s target is unmeasured. Incremental recognition remains contingent on this benchmark.
- [ ] Live private Blob upload, seek/range playback, interrupted-upload retry, comments, cleanup and revocation smoke checks before service deployment.

## Agent package and publication

Root plugin candidate **0.17.2** documents the optional original-selection and
instruction fields on native dictation history. Existing grants remain off by
default. No new action/schema or Linux implementation is introduced. Agent
`share.publish` keeps recording-text behavior; direct video publishing is a
person-initiated UI workflow. Brain 0.16.0, Linux 0.17.0 and Grok 0.12.0 stay
unchanged.

The candidate is prepared, not submitted or host-verified. After validation,
Tommy's next marketplace step is an authorized update email to
`marketplace-publishing@cursor.com`, with org `@muckstack`, repository
`https://github.com/tommy-muckstack/myman`, and candidate `0.17.2`, under the
[release policy](cursor-marketplace-release.md). No email, form, app release or
service deployment was sent.
