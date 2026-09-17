# Meeting slide capture hang

The Sentry export for issue 7736485267 reported a main-thread hang of at least
three seconds in My Man 1.1.75 (87). Its arm64 debug ID matched the installed
release binary: `93B14080-EE92-3A6B-9DED-9A88998B0256`. Symbolicating the two
app-relative addresses with that binary recovered:

- `0x384fb0`: `MeetingController.keepSlideIfChanged`, at PNG encoding on line 746.
- `0x383d88`: `MeetingController.captureSlide`.

The recording controller is main-actor isolated. Its periodic capture awaited
screen capture and OCR, then synchronously fingerprinted, PNG-encoded and wrote
the image on the main actor. The report identifies this blocking path; it does
not establish that all reported hangs have the same cause.

## Change

`MeetingSlideCapture` moves fingerprinting, PNG encoding and atomic writes to a
detached utility task. Only a successfully written slide advances the saved
paths and deduplication fingerprint. Capture and OCR remain limited to one
in-flight operation per recording. The 24-slide cap still permits participant
inspection of subsequent captures.

Stopping or discarding a recording invalidates its session and cancels its
pending write. A late write is removed off the main actor and cannot update a
new recording. Pending screen captures and OCR results are checked against the
session before proceeding. Each recording gets a fresh participant scanner,
and participant updates check the meeting identity after OCR returns.

## Regression coverage

- A deliberately blocked writer runs off the main thread while a main-actor
  continuation stays responsive; overlapping capture ticks are skipped.
- Stopping during screen capture, OCR or a non-cancellable write prevents late
  slide publication, and does not disturb a subsequent meeting.
- A failed write does not consume a slide slot or suppress retrying that image.
- Saved PNGs decode with the original dimensions.
- Duplicate suppression and the slide cap remain intact, with participant
  inspection continuing after the cap.

All fixtures are synthetic. No live screen capture, microphone or speech model
is needed for these tests. This native fix does not change agent tools or plugin
artifacts, so no marketplace version bump is needed.
