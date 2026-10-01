# Sentry investigation — October 1, 2026

Initially investigated at `f701a58`, preserving unrelated work. The release
candidate applies the fixes to `bf993db` (current main) for 1.1.104 (116).
Sentry issue statuses remain unchanged; the UI crash is not confirmed resolved.

## Historical events verified through the authenticated Sentry MCP

| Issue | Exact event | UTC timestamp | Release | OS |
| --- | --- | --- | --- | --- |
| [MYMAN-V](https://muckstack.sentry.io/issues/7756773623/) | `29cf92835d714b75bfae62efcb2858cc` | September 25, 06:41:13 | `myman@1.1.98+110` | macOS 26.6.2 / 25G83 |
| [MYMAN-X](https://muckstack.sentry.io/issues/7766453808/) | `ef09164b87374239937db27bc1821552` | October 1, 17:31:43.672 | `myman@1.1.103+115` | macOS 26.6.2 / 25G83 |
| [MYMAN-W](https://muckstack.sentry.io/issues/7766278719/) | `8bd9d2c696604a76987178fbd36ecd13` | October 1, 15:50:00 | `myman@1.1.103+115` | macOS 26.7.1 / 25G241 |

All event prefixes and trace IDs match the handoff. Retrieved every listed
thread (57, 32, and 22 respectively), plus all breadcrumb responses. No event
has attachments. MCP truncates long individual breadcrumb values; these
responses are not raw event JSON. Raw investigation evidence is retained locally and is not committed.

Release tags resolve to `5af384f` (v1.1.98) and `57faf3a` (v1.1.103).
The affected audio and meeting-startup code is unchanged between those tags
and the pre-fix checkout. The `main.swift` event-loop lines also match; its
unrelated action-routing difference does not establish a crash cause.

## MYMAN-X — confirmed main-thread AppleScript hang

Thread 0 runs `MeetingController.startAuthorized` line 554 →
`pauseMusicIfPlaying` line 1987 → `runAppleScript` line 2003 → OSA compilation
→ `PromptUserForApplication` → a nested event loop. This is the Spotify
script. Its `is running` guard does not prevent application lookup during
compilation. Both scripts were executed synchronously on the main actor.

`MeetingMusicPlayback` now checks for a running player before compiling a
script, uses bundle IDs, and executes `/usr/bin/osascript` on a serial worker
queue. An outer two-second deadline covers compilation and consent prompts;
stalled children receive SIGTERM and then SIGKILL after 250 ms if necessary.
Children also participate in the existing app shutdown registry. Meeting
startup/Stop never waits for the script. FIFO ordering preserves pause/resume
order when Stop arrives during a pause or another meeting starts immediately.
Only players successfully paused by MyMan are resumed (the old code resumed
Music even when only Spotify had been paused).

## MYMAN-V — confirmed retained-engine bug; crash causality not proven

The fatal thread is 33: `AVAudioIOUnit::IOUnitPropertyListener` →
`AVAudioIOUnit_OSX::_GetHWFormat` → channel-layout comparison →
`_xzm_xzone_malloc_freelist_outlined`. Fifteen threads are simultaneously in
the audio property listener. The main thread is idle. There is no application
frame on the fatal stack identifying an invalid write or ownership violation.

Source inspection found a definite lifetime bug: the block notification
observer strongly captured each engine, its token was discarded, and
`discardEngine()` never removed it. Retired graphs therefore stayed alive
and subscribed to device changes. The fix owns the registration, removes it
before graph teardown, and captures the engine weakly in both the observer
and queued callback. The existing current-engine identity guard rejects
callbacks from retired graphs. Regression tests cover observer removal,
engine deallocation, and repeated rebuilds releasing closure captures without
opening a microphone.

This eliminates a concrete source of accumulated audio listeners consistent
with the report. It does **not** prove that this leak caused the allocator
trap, or exclude another memory-corruption/framework defect.

The 1.1.98 application frames lack source symbols. The supplied PDF reports a
processing error, but the available MCP catalog does not expose processing
errors, raw event JSON, debug images, or debug-file lookup; its rendered issue
details omit those fields. No authenticated Chrome session or local .ips was
available. The existing release token already failed event reads in the prior
investigation, so it was not retried. Exact missing UUIDs/processing errors
remain unverified. The upload script still warns rather than failing releases
when symbols cannot be uploaded; no upload or production-policy change was made.

## MYMAN-W — reporting defect fixed; underlying UI exception unresolved

Thread 0 ends at `+[NSApplication _crashOnException:]`, reached from a
CATransaction display flush. `main.swift:563` is `app.run()`, not evidence of
a failure in the launch closure or `MainActor.assumeIsolated`. Breadcrumbs
show lifecycle/network traffic without the failing view or action. Neither
the original exception reason nor the original throwing stack is available.

This is the reporting failure documented in Sentry
[issue 7136](https://github.com/getsentry/sentry-cocoa/issues/7136), fixed by
[PR 7510](https://github.com/getsentry/sentry-cocoa/pull/7510), first shipped
in 9.7.0. MyMan pinned 8.58.4 and did not enable AppKit exception interception.
The dependency is now pinned to 9.7.0 and `enableUncaughtNSExceptionReporting`
is enabled. The upstream fix captures both class and instance AppKit exception
paths synchronously before termination, preserving the original NSException.
No custom exception suppression or speculative view changes were added.

Reviewed the [8-to-9 migration guide](https://docs.sentry.io/platforms/apple/migration/v8-to-v9/):
the SDK requires Swift 6 tooling; its macOS 10.14 minimum remains below MyMan's
14.2 floor. Other dependency pins are unchanged, and tracing remains disabled.
The original UI fault still needs an original macOS .ips report, a reproducible
UI sequence, or a future event captured with the corrected SDK. It is not
accurate to mark this application crash as resolved.

## Verification

The pre-change `swift test` build failed at `AgentActions.swift:548,556`:
two asynchronous GRDB reads omitted `await` and returned non-Sendable `Row`s.
The older checkout needed awaited scalar ID reads to compile. Current main
already awaits these queries, so the release candidate does not change
`AgentActions.swift`.

- `swift test`: **452 tests, 39 skipped, zero failures**, including 10 new
  regression tests (3 audio observer lifetime tests and 7 music-control tests).
  The new tests exercise real child-process timeout and forced termination,
  off-main execution, stop-during-pause ordering, and player-specific resume.
- Initial focused run: the existing 3 `AudioEngineSafetyTests` also passed.
- `swift build -c release`: passed (native arm64, 259 seconds). `dwarfdump`
  confirms the executable and generated dSYM share UUID
  `6472A423-E328-3EEE-9F16-E4841E1AF2AA`. This verifies local symbol generation,
  not Sentry upload or historical symbol availability. The build log is
  retained locally.
- `git diff --check`: clean.
- Original test and failed pre-change build logs are retained locally.
- The 39 skips are existing opt-in/fixture-dependent tests. Physical device
  switching, real Music/Spotify automation consent, and the historical UI
  crash were not reproduced. Tests do not prove production crash elimination.

Files changed for this investigation: `Package.swift`, `Package.resolved`,
`src/Core/CrashReporting.swift`,
`src/Meetings/MeetingController.swift`, `src/Meetings/MeetingMusicPlayback.swift`,
`src/Voice/AudioCapture.swift`, `src/Voice/AudioEngineConfigurationObservation.swift`,
the two corresponding new test files, release version metadata in
`scripts/build-direct.sh`, and this report.

The test results above describe the initial checkout. Release-candidate
verification on current main is tracked in the 1.1.104 release pull request.
