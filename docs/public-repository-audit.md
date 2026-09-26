# Public repository audit — September 11, 2026

The app and Brain companion select the current user's local data. Installing
the source or plugin does not connect to the maintainer's Brain or Mac.

## Data and configuration

- `src/Core/Brain.swift` builds its export path from
  `FileManager.default.homeDirectoryForCurrentUser` and `MyManBrain`.
- `integrations/brain/brain.mjs` defaults to `os.homedir()/MyManBrain`.
  `MYMAN_BRAIN_ROOT` can select another local folder; CLI `--root` takes
  precedence. There is no bundled override.
- `mcp.json` resolves the companion relative to `${PLUGIN_ROOT}`. It contains
  no machine-specific checkout path or account credential.
- No personal Brain exports, app databases, environment files, private keys,
  or provider access tokens were found among the current tracked files.
- The companion has no network transport or account login. A connected hosted
  agent can send retrieved content to its model provider.

## Cleanup

Personal names and a work email in speaker examples, test fixtures, comments,
and agent instructions were replaced with fictional names and example.com
addresses. Unicode participant matching remains covered by an accented
fictional name. Setup documentation now explains per-user path resolution.
The ignore rules also exclude MyManBrain directories and SQLite files.

## Maintainer references and remaining qualifications

- Repository URLs, CODEOWNERS, copyright, the security contact, bundle IDs,
  and product vocabulary retain public maintainer/product attribution.
- Release scripts target the maintainer's signing setup, public update feed,
  and distribution services. The development runner also includes the official
  update feed. These are release/update connections, not Brain access.
  Fork maintainers should review these settings before distributing builds.
- Current telemetry configuration is injected from local ignored files or
  build environment variables. A fresh source checkout has no telemetry key.
  Official builds can report analytics and crashes; analytics currently include
  the machine's hostname, so they should not be described as strictly anonymous.
- Git history contains a formerly hardcoded Amplitude ingestion key in
  `src/Core/Analytics.swift` (for example, commit `ef1e906c27`). Its value was
  not reproduced in this report, and its current validity was not checked.
- Historical commits retain older personal examples and commit author email
  metadata. Editing current files does not remove historical copies.
- Gellix font files retain their proprietary copyright metadata. Public
  redistribution permission was not established by this audit. The files were
  left unchanged at the maintainer's request. See the foundry's
  [license terms](https://displaay.net/help/licenses).
  Linux packages (tarball, AUR, source install) ship no Gellix: demo captions
  use Outfit SemiBold (SIL Open Font License 1.1, license text in
  `src/Resources/Fonts/Outfit-OFL.txt`) on both platforms.

## Verification and limits

Reviewed the current tracked source/configuration and visually inspected all
13 documentation screenshots, which showed sample UI content. Pattern-scanned
879 Git blobs under 2 MB across 282 commits reachable from local refs for
personal home paths, common provider token formats, literal credentials, and
private key headers. Binary historical assets and remote-only refs, issues,
pull requests, release artifacts, and external backups were not audited.
Pattern scans cannot establish the absence of every possible secret.

After cleanup, all 21 Node companion tests and all 27 selected Swift tests
(`MeetingTranscriptTests` and `BrainAgentExportTests`) passed. The fixtures
use synthetic data. No private Brain contents were needed for this audit.

## Follow-up — September 15, 2026

Files that landed after the September 11 pass still carried the earlier
first-name examples in agent instructions, companion tests, the CLI/tool
descriptions, and two Swift fixtures. Those were replaced with the same
fictional names, and the bundled companion under `src/Resources/BrainCompanion`
was regenerated with `npm run bundle`. Maintainer attribution in release and
marketplace docs is unchanged. All 92 Node companion tests and the 46 Swift
tests covering the changed fixtures passed.
