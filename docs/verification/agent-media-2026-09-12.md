# Agent media workflow verification — September 12, 2026

Candidate: MyMan 1.1.61 (73), companion/plugins 0.5.0, 58 native actions. Brain MCP remains retrieval-only with ten tools. This change extends the existing capture renderer, recording controller, library lifecycle and CLI bridge.

## Automated checks

- Full native suite: 155 tests, 6 opt-in skips, zero failures.
- Media, permission and native protocol checks: 14 tests, zero failures. Includes stable OCR targeting/ambiguity, rendered circles and callouts, source preservation, label placement, temporary preview cleanup, invalid frame/trim bounds, playable frame extraction, trim/export, segment joining and undersized export rejection.
- CLI/companion suite: 75 tests, zero failures. Includes new resource commands, native argument shapes, preview side-effect conflicts, target errors, packaged MCP and existing retrieval/security cases.
- Both agent skills validate. Committed companion matches source through `check-bundle`.
- Debug and universal release builds (Apple Silicon and Intel) pass.

## Isolated native CLI smoke

The debug verification app uses a separate database, Brain, capture folder and owner-only Unix socket. Only its synthetic fixture window is recorded. Tests use microphone/system audio/webcam off and do not inspect personal captures.

| Workflow | Result |
| --- | --- |
| Import fixture and return attachment metadata | Pass; 1800 × 1200 source pixels, file size and thumbnail path |
| Find OCR region and render circle/callout preview | Pass; selected line geometry, temporary PNG, no saved preview item |
| Save markup | Pass; new ID/path, original remains intact; rendered output visually inspected |
| Reject conflicting window/display arguments | Pass |
| Window recording with two-second limit | Pass; auto-finalized playable 2.21-second movie (includes capture shutdown latency) |
| Stop a finalized session | Pass; returns the same saved item |
| Extract three frames and contact sheet | Pass; temporary PNG paths and timestamps |
| Trim and MP4 export | Pass; 1.3-second clip, 72,532 bytes, original preserved |
| Pause/resume | Pass; one session, 2.88-second final video across 4.98 seconds of wall time |
| Cancel | Pass; no saved take; terminal cancelled state |
| Unknown session | Pass; cannot stop a different recording |
| Source exclusion | Pass; temporary derived previews removed |

These figures record the first complete native smoke run. The final recheck passed all 14 checks, including automatic finalization while paused (0.65 seconds of recorded content), window recording (2.16 seconds), trimmed MP4 export (1.3 seconds), and pause/resume (3.09 seconds of video across 5.40 seconds of wall time). Runtime output and recordings stay outside the repository; no personal Brain data is committed.

## Limits and remaining host checks

- OCR selection is line-level, lexical and on-device. It is not an arbitrary UI selector or semantic object detector.
- Callout placement minimizes overlap among a bounded set of positions; agents should inspect complex layouts before saving.
- Microphone-on, webcam-on and audio listening quality are not claimed by the muted-window smoke. The existing raw narration pipeline remains in use; resumed segments use their own start time and report failed narration merges.
- Window-only recordings intentionally reject a separate webcam bubble. Display/region recording retains it.
- Duration limits include paused wall time and can incur shutdown latency. Session results are in-memory for the current launch; the saved file/library item is the persistent artifact.
- Size-capped export may lower resolution and errors if a complete clip cannot fit. It does not silently truncate to fit a byte limit.
- Agent-host attachment sending, Cursor/GrokBot activation and marketplace approval are not simulated by local CLI tests.
