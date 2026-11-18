# Background performance — 1.1.117 (129)

This release reduces optional maintenance work. The observed MyMan CPU spike was
transient and was not profiled, so this is not a claim that its exact cause has
been reproduced or eliminated.

## Changes

- Coalesce bursts of scan/enrichment requests, including requests arriving during
  a running pass, into at most one follow-up pass.
- Defer optional indexing, screenshot backfill and theme work during Low Power
  Mode, serious/critical thermal pressure, or sustained system load above 1.5
  runnable tasks per active processor. Retry without busy polling. Recording,
  dictation and user searches do not use this gate.
- Cache relationship evidence by capture revision and effective title. Recompute
  candidates against the current corpus, score only affected sources, and write
  only changed relationship rows. Validate the snapshot before committing either
  the database results or the in-memory cache. This includes edits, exclusions,
  deletions and corpus-size changes affecting candidate pruning.
- Skip generated Rust, Swift and Xcode build trees during note scans, including
  for existing saved exclusion settings. Add timer leeway and idempotent startup.
- Log local maintenance durations and workload counts without source content,
  identifiers or paths. No new remote telemetry or permissions.

## Verification

Synthetic tests cover coalescing during work, deferred work resuming, pressure
policy, unchanged-library no-op behavior, incremental/fresh equivalence across
edits/additions/deletions, candidate limits, database-trigger invalidation,
generated titles without revision changes, and generated-folder exclusions.

A 1,000-item fixture checks that one edited item analyzes one item's evidence and
scores 90 affected pairs instead of the initial 9,000; an unchanged pass scores
none. These are operation counts, not a measured percentage reduction in app CPU.

Local debug build passed. The full native suite passed: 700 tests, 51 optional
skips, zero failures. The 1,000-item operation-count fixture passed.

Release gates: universal Intel/Apple silicon compilation, green CI, Developer ID
signature validation, Apple notarization/stapling, and verification of the
published installer and Sparkle feed. Artifact results are recorded in the PR
and GitHub release.
