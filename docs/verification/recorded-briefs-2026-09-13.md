# Recorded briefs and visual proof verification

Candidate: My Man **1.1.66 (78)**; companion/root/GrokBot plugin **0.9.0**. Native actions are discovered from the installed app. My Man 1.1.65 is the previously published version and does not include brief actions.

- Native suite: **182 tests, seven existing opt-in skips, zero failures**. Focused brief suite rerun after the HTML and video validation changes: five tests, zero failures. Tests cover independent worker/reviewer roles, revision conflicts, evidence requirements, source change invalidation, explicit refresh, persistence, deletion, human-created briefs, and portable/inert HTML.
- Companion suite: **91 tests passed**, no skips. Committed bundle freshness and both skill validators passed.
- Debug build and universal Intel/Apple Silicon release build passed.
- An isolated debug app with a generated four-second video and synthetic screenshots completed **19 packaged CLI calls plus two independent packaged MCP clients**. It rejected out-of-range video timestamps, extracted two timestamped frames, persisted a worker/reviewer handoff, rejected the wrong worker and self-review, rejected a missing library scope and stale revision, required export confirmation, and returned a local share page after review. The transcript was explicitly labeled untimed. The page was checked for fixture credential/path/transcript leakage. No personal capture data was used.
- Native workspace, composer and share-sheet controls were inspected in the running preview. [Workspace](recorded-brief-workspace.png), [composer](recorded-brief-composer.png).
- Browser verification at desktop and 390px mobile widths: embedded image loaded, Gellix loaded, no horizontal overflow, no browser errors. [Desktop](recorded-brief-share-desktop.png), [mobile](recorded-brief-share-mobile.png). Browser inspection caught a Swift overload ambiguity that rendered a GRDB SQL debug description instead of image markup; the join now explicitly returns String and a regression checks the actual image element.

The launcher result and theme rows now show their background and border only while hovered. Keyboard actions and accessibility selection remain available; the default first result no longer looks persistently selected.

## Product and data boundaries

Briefs retain source IDs/revisions and explicitly authored instructions, not duplicate source transcripts/videos. A worker submits saved output IDs with at least one visual. A different assigned reviewer must cover every criterion; passing checks cite submitted evidence. The reviewed state records that reviewer's judgment and is not an automated correctness guarantee. Refresh resets assignments and prior proof metadata. Deleting/excluding a referenced source or result invalidates the brief.

Share pages contain only selected submitted result media and separately supplied public copy. They embed no private brief, source paths, credentials or agent names. Exports load no remote resources and contain no tracking scripts. Library lifecycle does not revoke copies that a human has independently saved or shared. Official-app analytics add only recipe/stage kinds and counts for creation, review progression and share preparation; there is no claim to measure a GrokBot template installation.

## Remaining external acceptance

Actual GrokBot plugin installation, dispatch to the chosen Mac, separate per-Bot credential configuration and attachment delivery have **not been verified in GrokBot**. Local CLI/MCP success does not prove them. The workflow check reports those host checks as not tested. Public Bot share links must be created through GrokBot; no fabricated link or account-specific template is shipped.

The initial Cursor marketplace application remains recorded as pending. Candidate 0.9.0 is prepared; no update email, duplicate form, marketplace approval or app publication is claimed by this report. Next authorized marketplace step: notify marketplace-publishing@cursor.com with @muckstack, https://github.com/tommy-muckstack/myman and 0.9.0.
