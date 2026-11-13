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

## Interview v4 evaluation (2026-09-21)

The v4 candidate carries the unfinished v2/v3 work forward. It is not a release or an acceptance pass. The new exchange-first interview format is gated by the off-by-default `meetingInterviewNotesExperimental` preference; the separate experimental topic pipeline remains gated as before.

Changes under evaluation:

- Detect punctuation-free questions and response invitations in both directions. Render separate owner-answer and peer-answer blocks, merge related follow-ups, and trim the next question out of the preceding answer.
- Suppress tightly interleaved acknowledgment/noise candidates from summary inputs and the reading view. Preserve every raw turn and timestamp, and export the candidates and rationale separately. Legacy start-only timestamps cannot establish a measured sub-1.5-second duration.
- Keep paragraph grouping bounded by a 15-second gap. Raw editing and timestamp lookup still use individual turns.
- Exclude historical story answer spans from interview commitments. Recognize first-person future promises, including “I'm gonna”, and keep the inferred thank-you distinct from spoken commitments and generated tasks.
- Compare actual prepared-question sections with questions the owner asked. Compound questions can be partly matched; research prose is not treated as an interview plan.
- Include standing tool/acronym terms in CI context, while requiring occurrence-level recognizer confidence. Preserve canonical terms and restrict acronym substitutions to known confusion pairs. Reject multi-token person-name matches that could turn an abbreviation plus a common word into a name.
- Use the on-device model to select bounded source passage indices. The application retrieves and timestamps the selected wording; the model cannot invent a paraphrase. These are explicitly labeled extractive digests, and missing coverage remains a failure rather than being padded with invented bullets.
- Produce an interview draft with the owner's personal interpretation section blank. Its schema alone does not satisfy content acceptance.

The paired private review calls `MeetingNotesService.generateBounded`, the production notes entry point, on an isolated SQLite snapshot. The same harness can opt into audio re-decoding into a separate checkpoint and audit the resulting occurrence-level confidence. No private recordings, expected answers, reviewed prose, or company files are repository fixtures.

Reproduction uses `MAN_INTERVIEW_V4_DIR` (containing `input.sqlite`), `MAN_INTERVIEW_V4_IDS` (two comma-separated IDs), and `MAN_INTERVIEW_COMPANY_FOLDER`, with `swift test --filter MeetingSummaryV4Tests`. `MAN_INTERVIEW_RETRANSCRIBE=1` optionally produces private audio checkpoints; `MAN_INTERVIEW_USE_REDECODED=1` evaluates that candidate transcript. Neither replaces live meeting data. Test success means the harness ran; the generated files must still pass the content acceptance checks.
