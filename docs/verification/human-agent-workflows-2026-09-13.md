# Human and agent workflow verification — September 13–14, 2026

Candidate: My Man 1.1.67 (79), companion/root/Grok plugin 0.10.0. All captures, transcripts and credentials used in fixture tests are synthetic. The original dirty checkout remains untouched.

## Observed results

- **Automated checks:** 194 native tests completed with 8 opt-in tests skipped and zero failures; the actual dictation insertion opt-in then passed separately. Companion tests: 92 passed. Share service tests: 5 passed. Debug and universal Intel/Apple Silicon release builds passed; both skill packages validated.

- **Real Grok Bot / Hugo:** the local-computer command reached the isolated Mac app with the matching challenge. Hugo returned the generated PNG as an inline attachment; Tommy supplied the visible screenshot confirming delivery. This validates Mac execution and file return. It does not establish marketplace approval, public Bot-template publication, or independent host-agent dispatch.
- **Recorded briefs:** 19 CLI commands and two MCP clients passed creation, source-frame extraction, worker/reviewer ownership, per-criterion review, guarded edits and selected HTML export. Results remain associated with the original brief. Two timed frames were returned; untimed transcript text remained explicitly untimed.
- **Human workflow CLI:** 12 commands passed mixed note/meeting/screenshot handoff, attachment bounds, scope denial, floating reference, activity receipts, unsupported cancellation rejection and source-exclusion handling.
- **Sharing server:** real HTTPS publication, immediate revocation and timed expiry passed. The copied URL returned HTTP 410 after revocation and after its 60-second test expiration. Responses were non-cacheable. Unit checks also cover HEAD, authentication, input bounds, script isolation and storage failure.
- **Native sharing client:** Keychain-backed publish and revoke passed; another named agent could not revoke the publisher's share. Synthetic source content only.
- **Accessibility inspection:** new Workflows controls are exposed as native accessible buttons and segmented choices. Captured the isolated native window at standard and 150% text size and inspected its layout; enlarged text uses a menu for navigation to keep every section reachable. [Largest-text screenshot](human-agent-workflows-large-text.png). Keyboard/VoiceOver capture chooser, human focus outline, larger text and announcements are implemented. This is a targeted audit, not blanket accessibility certification for legacy editors.
- **Scrolling assembly:** deterministic overlapping-image tests preserve source rows and reject unchanged/unsupported input; ambiguous repeated patterns do not silently append.
- **Actual dictation insertion:** opt-in integration test passed against a temporary TextEdit document, verifying the focused process/document before sending Unicode text and requiring the delivery result to be verified.
- **Recovery:** source evidence and revision guards, preserved corrupt dictation history, Unicode-safe replacement, app-specific style isolation, and durable receipt references across restart passed native tests.

## Repeatable scorecard

Run `node integrations/brain/test-workflows-live.mjs <isolated-verification-root>` against the debug fixture app. It writes action durations and outcomes. September 13 sample (one warm developer Mac run; CLI startup included):

| Task | Observed My Man time | Outcome |
| --- | ---: | --- |
| Create synthetic note | 302 ms | Saved |
| Import synthetic screenshot | 842 ms | Saved |
| Export selected note + screenshot + meeting | 287 ms | Markdown plus image prepared |
| Open floating screenshot | 360 ms | Native reference window opened |
| Open workflow activity | 270 ms | Native activity opened |

These are smoke measurements, not statistically representative latency claims. Compare products using the same source, Mac, permissions, warm/cold state and network conditions. Record task success, elapsed time, manual corrections, and recovery after interruption. Suggested tasks: scrolling screenshot with fixed header; screenshot annotation/export; five-minute meeting with corrected speaker and cited decision; dictation into three apps followed by focus change; selected capture handed to an agent and returned as a file; revoke a previously opened share.

CleanShot X, Granola and Wispr Flow were **not timed** in this run. No “faster/better than” benchmark is claimed. Their current public capabilities informed the scope; product differentiation should be judged by the completed capture-to-result workflow and observed reliability.

## Reproduce

```sh
swift test
swift build -c release --arch arm64 --arch x86_64
npm ci --ignore-scripts --prefix integrations/brain
npm test --prefix integrations/brain
npm run check-bundle --prefix integrations/brain
npm ci --ignore-scripts --prefix integrations/share-service
npm test --prefix integrations/share-service
```

Live fixtures additionally use `test-briefs-live.mjs`, `test-workflows-live.mjs`, and `test-sharing-live.mjs`. They require a path beginning `/private/tmp/man-verification-` and its explicit isolated socket/credential fixtures. Never point them at a real library. The publishing fixture requires an explicitly configured personal service.

Marketplace status: initial @muckstack publisher application remains pending. Candidate 0.10.0 and four starter instruction files are prepared; no update email/form or public Grok Bot template was submitted by this change.
