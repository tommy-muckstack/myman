# Quitting My Man

Quit ends the app's capture sessions, including meeting and dictation starts
that are waiting for permission or microphone hardware. A late callback cannot
restart capture. Calendar and microphone detection stop initiating meetings as
soon as termination begins.

Committed meetings retain their WAV audio, recording note, title, transcript,
and summary. Quit closes WAV headers, records the end time, and leaves unfinished
transcription for recovery on the next launch. Unclaimed provisional meetings
follow their existing discard behavior. Pending transcription and note jobs are
cancelled rather than awaited during termination.

Screen recording gets an opportunity to finalize normally. If finalization
stalls, the existing video segments and narration sidecar remain on disk, with
recovery paths in the session receipt. Quit allows at most eight seconds for
asynchronous cleanup; it does not wait for a stuck model or CoreAudio response.

App-owned child processes receive termination and then a forced stop after a
short grace period, including their descendant processes. Other applications'
servers are never selected by executable name or port. A PID's creation time
is checked before stopping a previously discovered descendant.

Update checks and downloads keep their existing behavior while the app runs.
An explicit Quit is no longer vetoed by the updater's recording-busy state.

Regression coverage in `AppTerminationTests` exercises delayed permission,
idempotent and timed-out quit, meeting preservation, queued ASR cancellation,
closed WAV headers, the microphone startup fence, and owned helper cleanup.
