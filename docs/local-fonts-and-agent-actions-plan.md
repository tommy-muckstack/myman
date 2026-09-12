# Local fonts and explicit agent actions

This work follows the separately published 1.1.58 release. It was implemented
and verified locally first; the user subsequently authorized publishing it in
1.1.59.

## Font integration

- Optional Create font action on a new or existing screenshot; no dedicated
  main toolbar destination.
- Underlying full-resolution pixels and optional region selection. Native
  Vision character boxes feed the existing local outline/metrics/font engine.
- Package a WKWebView workbench and 16 matching font styles with notices.
  Block remote loading and verify the packaged app without networking.
- Measure a style from captured outlines and construct missing basic Latin
  glyphs using target-specific skeletons; captured glyphs always win. Track
  support and uncertainty, permit review/exclusion/replacement, keep matching
  and optional external fallback separate, and offer captured-only export.
- Preview the actual OpenType CFF bytes; save through native controls. Reuse
  notes and owned document assets for searchable saved fonts and cleanup.
- Test geometry, OCR variants, lifecycle/cancellation, withheld glyphs from
  fonts outside the matching library, actual WKWebView and packaged operation.

## Full agent CLI

- Extend the existing bundled companion rather than introduce a second CLI.
- Add a local, same-user app command bridge with structured errors, job/session
  identifiers, and bounded payloads. No network listener or remote service.
- Reuse existing capture/editor/recording/meeting/dictation/document controllers
  for explicit agent invocations, preserving normal permissions and lifecycle.
- Cover screenshot capture/annotation/export/OCR, clipboard, recording control,
  meeting/dictation control, notes/tasks/themes, font operations and app status.
- Publish machine-readable action schemas/help and update bundled CLI/MCP,
  Brain instructions and skill discovery. Agents should discover capabilities
  and collect outputs without scraping the UI.
- Verify real action flows, including screenshot → markup → clipboard and
  recording start/stop → saved file; preserve the current read-only queries.

## Interface follow-ups

Use the calendar's centered invitation throughout empty utility surfaces. Keep
recent captures in the main search surface, with Themes under the supplied
funnel filter icon and history clearing in Settings. Use a single anchored
window expansion for live meeting titles.

Verification and remaining font fidelity limits are recorded in
[the local preview report](verification/local-tools-2026-09-11.md).
