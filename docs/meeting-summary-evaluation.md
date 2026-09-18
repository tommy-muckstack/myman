# Meeting summary evaluation status

This branch is a work in progress. Passing unit tests and compilation do not establish acceptable automatic summary quality.

## Implemented

- Join consecutive recorder chunks for reading while retaining the original transcript.
- Recover full interview answer spans across acknowledgments and nest related follow-ups.
- Extract exact quotes from both speakers and anchor quotes that cross chunk boundaries to their starting turn.
- Label the interview thank-you as inferred; do not create a task from that inference.
- Preserve recognizer confidence and original wording in transcript checkpoints. Scoped product/acronym corrections require low confidence for the specific occurrence and an unambiguous candidate.
- Retry isolated unexpected-script output in an established English conversation with an English recognizer, preserving original wording.
- Discover an unambiguous same-day interview prep file within a configured company folder.
- Make private-passage omission configurable and export ranges, reasons, and spelling corrections.
- Keep screenshot recording association separate from the off-topic hint.

## Evaluation blockers

Two owner-supplied recordings were evaluated locally. Their data and reviewed recovery artifacts are not committed.

- The interview exchange detector recovers three parent questions and follow-up counts of one, two, and zero. Quote extraction recovers the requested principles. The bundled model still drops answer content and can change a planned outcome into a completed outcome.
- The topic pipeline still mislabels subjects and omits important details in a separate meeting. It is gated behind the off-by-default `meetingTopicNotesExperimental` preference.
- A noun-overlap check is not an entailment check. Do not relax grounding merely to produce more bullets or report an extraction-harness success as an acceptance pass.
- Interview overview and template drafting remain incomplete. Role/context attribution must distinguish prep-file facts from statements actually heard.
- Source-reviewed recovery drafts must remain explicitly labeled as reviewed artifacts, not automatic outputs. They have not replaced live notes.

## Before release

1. Produce complete, faithful two-to-four-bullet answers for each parent question and follow-up; preserve tense, uncertainty, and examples.
2. Produce subject headings and coverage for the full meeting, correct next-step ownership, and provenance for any corroborated dates.
3. Draft the requested interview sections with the owner's personal interpretation section left blank.
4. Verify context correction against stored audio without globally weighting common words or learning vocabulary from the output being evaluated.
5. Run both private acceptance checks, the regression suite, and debug/universal release builds. Review the settings UI before release.

No new model runtime or model download has been added. A stronger on-device summarizer remains an option requiring a separate implementation and evaluation.
