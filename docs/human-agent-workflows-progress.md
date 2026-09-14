# Human and agent workflow release

Scope authorized September 13, 2026: complete the six product improvements discussed after 1.1.66. Work is additive to the released brief, capture, meeting, dictation and local agent surfaces.

## Delivery checklist

- [x] GrokBot: guided connection and Mac selection; explicit selected-file handoff; Mac execution/attachment acceptance; results return to original brief; four shareable starter instruction files; public host template publication is separate.
- [x] Accessibility: keyboard focus distinct from hover, actual buttons for gesture-only actions, VoiceOver labels/status announcements, scalable text and contrast, action parity checks.
- [x] Capture: scrolling capture and bounded stitching, floating references, fast copy/drag/export, optional share publishing with enforced expiry and revocation.
- [x] Meetings: speaker correction, timestamped source evidence, cross-meeting decision history, reviewed follow-up drafts including related captures.
- [x] Dictation: insertion/focus verification, recoverable failed delivery, correction learning, app-specific formatting, editable vocabulary and latency measurement.
- [x] Recovery: human-readable activity view for inputs/changes/results/failures and safe continuation using existing receipts.
- [x] Scorecard: repeatable tasks and measured success/time/corrections/recovery; competitor results only when actually observed.
- [x] Validation: meaningful native/companion tests, Intel/Apple Silicon builds, isolated native/browser checks, real-host acceptance separately recorded.
- [ ] Delivery: versioned app/plugin candidate, GitHub PR and green CI, authorized release and marketplace notification note.

## Baseline findings

- 1.1.66 contains briefs, separate worker/reviewer assignments, selected local HTML exports, live CLI checks, scoped named credentials and durable receipts. Real GrokBot dispatch and attachments have not been verified.
- Capture supports region/window images, annotation and a temporary draggable thumbnail. Scrolling capture and persistent floating references are missing.
- Themes already include notes, dictation, screenshots, meetings and recordings. A prior fix prevents shortcut hover narrowing an open theme.
- Dictation already has editable vocabulary, cleanup tones and stored transcripts. Delivery currently types without checking the destination field or reporting insertion failure.
- The original checkout has user changes and remains untouched. Work uses the clean release worktree and a new branch from main.

Implementation and synthetic verification are detailed in [the verification record](verification/human-agent-workflows-2026-09-13.md). Grok Bot Mac execution and actual image delivery were confirmed by Tommy. Competitor timing and blanket accessibility certification are not claimed.
