# Meeting processing latency

## Audit

- Speech transcription uses the existing Qwen3 accuracy model, with the existing Parakeet fallback. Mic and remote slices run serially; quiet-track recovery may require another pass. Slice sizes and silence-boundary detection protect recognition quality.
- Remote speaker identification previously started after both tracks finished transcribing. It uses separate FluidAudio models and its own actor.
- Notes previously started only when the user opened the document. Long meetings require compression, reduction, final writing, and a separate commitment extraction pass with evidence checks.
- Launch warmup and a meeting could both enter Qwen model loading before either had finished, creating duplicate downloads/compilation/warmup.
- The existing transcript completion wrote a stale full meeting snapshot, which could overwrite notes or title edits made during processing.

## Changes

1. Start remote speaker identification alongside transcription; join before assigning labels. Preserve the known-attendee shortcut and serialize ASR slices as before. An internal sequential switch supports repeatable comparisons.
2. Prepare notes immediately after the transcript is saved, independently of document opening. Share one active job per meeting and limit text generation to one meeting at a time. Reopening joins ongoing work; completed results use the existing database row.
3. Share Qwen loading across concurrent callers; retain successful models and allow retries after failure. Speaker identification also joins an existing launch warmup instead of silently skipping labels while models are still loading.
4. Use conditional, field-only writes. Respect edited notes, corrected transcripts, and deletion. Cancel notes processing on editing/deletion, and do not retain completed transcript/result caches.
5. Observe the saved meeting in open editors so completed transcription and notes appear without reopening. Show transcript-reading and commitment-check progress.
6. Record content-free monotonic stage timings for model readiness, transcription, speaker identification, note compression/writing, and commitment checks.

The speech model, prompts, audio slices, full-transcript processing, speaker rules, and action-item validation are unchanged. No cloud processing, migrations, or dependency updates.

## Verification

`swift test` covers job sharing, warmup sharing/retries, bounded generation, edits during processing, deletion, and conditional transcript saves, alongside the existing speech and editor regression suite.

For a local before/after scheduling comparison, create a synthetic mono 16kHz speech file and run:

```sh
MAN_SYNTHETIC_BENCHMARK_AUDIO=/path/to/synthetic.aiff swift test --filter MeetingProcessingBenchmarkTests
```

The opt-in test uses installed models, warms the baseline, alternates sequential and overlapped scheduling, and requires identical transcripts and speaker labels. Normal tests skip model inference. Small synthetic fixtures cannot predict speedups for long meetings or other Macs; shipped stage timings support follow-up diagnosis.

Local result (September 11, 2026): an 11.84-second synthesized speech fixture took 2.461/2.501 seconds sequentially versus 2.311/2.391 seconds with overlap (means 2.481 versus 2.351 seconds, about 5.2% less time). All four outputs matched the warm baseline exactly. This measures speaker/transcription scheduling only; earlier note preparation and duplicate-warmup prevention are separate improvements.
