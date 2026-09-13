# Collaborating through MyMan

MyMan supplies deliberately invoked capture tools, shared source references and coordination. The user's agent host decides who works and when. MyMan does not launch bots, execute handoff instructions, send messages or upload attachments.

## Example workflows

**Demo recap.** The capture agent finds the demo meeting and its screenshots and creates a bundle. A design bot selects and annotates the best screens while a research bot summarizes the meeting. An editing bot takes their outputs and prepares a walkthrough. The final bundle links to the original material.

**Deployment review.** The capture agent captures the deployed page on the explicitly selected Mac. A design bot compares it with the reference while a second bot checks the copy. Each saves a separate annotated image, and the user receives a shared bundle of findings.

**Font handoff.** A capture bot collects large, consistent text samples. A font bot generates an OpenType file and quality report. A review bot prepares specimens using the requested text, then returns the source references, font and preview through its host.

**Recorded tutorial.** The capture agent starts and owns a recording. Another bot prepares caption text and numbered steps. The capture agent either stops the recording or explicitly transfers the session to the editing bot. Once finalized, an editor exports a finished copy. The human can always use MyMan's recording controls.

## Setup and identity

In Settings → Agents, add each bot with its own name and scopes. Adding the first agent enables **Require named agent credentials**; configure existing hosts before using them again. The app shows each new credential once. Store it in the host's secret/environment configuration as `MYMAN_AGENT_TOKEN`, never in prompts, screenshots, repository files or command arguments. Revocation is available in Settings; no CLI or MCP tool can issue credentials or increase permissions.

Set `MYMAN_MACHINE_ID` to the ID displayed in Settings, or pass `--machine ID` on native CLI commands. `machine current` and live discovery identify the connected Mac. A mismatch fails before execution. Each Mac has its own registry, credentials, capture IDs and collaboration state. The agent host must run the CLI/MCP process on the chosen Mac through its existing approved local-computer connection. This release adds no remote listener, cross-Mac synchronization or SSH configuration. `--root` still selects a local Brain export, not another Mac.

Credentials attribute and scope **app bridge** actions. They are not an OS sandbox: processes sharing a macOS login can independently read accessible files, including Brain exports. Per-agent scopes intersect the existing global capture/markup/recording/library switches. Read-only Brain retrieval remains a separate server. Keep mutually untrusted programs in separate OS accounts or machines.

```sh
myman machine current --json
myman agent whoami --json
myman agent list --json
```

MCP hosts get the same commands as `myman_app_bundle_create`, `myman_app_handoff_update`, and so on, through the separate app server. Configure credentials and Mac ID in each MCP process's environment. Jobs are private to their originating identity; sharing an ID does not transfer authorization. Use handoffs and bundles to share results.

## Shared bundles and guarded edits

```sh
myman bundle create --title 'Demo references' --item-ids '["meeting-ID","shot-ID"]' --members '["DESIGN-AGENT-ID"]' --json
myman bundle read --id BUNDLE-ID --json
myman bundle update --id BUNDLE-ID --expected-revision 1 --title 'Reviewed references' --json
```

A bundle holds up to 100 distinct item IDs and their revisions. Its creator chooses registered members; members can update its title/references using the current revision. Only the creator can change membership or delete it. Read responses flag changed or unavailable sources; these are **references, not immutable snapshots**. Use separate exported or annotated copies when a fixed artifact is needed. Bundle membership grants access to the bundle, not an independent restriction on the underlying library's existing access.

Named agents must supply `expected_updated_at` for note replacement, append and image attachment; `expected_revision` for item rename, pin, hide and delete; and `expected_version` for task/theme mutations. Get the latter using `resource version --kind task|theme --id ID`; merging themes also requires `target_version`. Conflicts fail instead of overwriting. Screenshot markup and video exports already create new artifacts, allowing parallel proposals from the same source.

## Ownership and temporary reservations

Recording, meeting and dictation sessions belong to their initiating identity. Other agents cannot pause, stop, discard, rename or change the microphone on that session. Ownership persists across app restart, while interrupted capture work is never restarted automatically. A human-created session stays under human control. The owner may transfer a session explicitly:

```sh
myman session transfer --session-id SESSION-ID --recipient EDITOR-AGENT-ID --json
```

For a short sequence of related edits, reserve an item or the clipboard:

```sh
myman lease acquire --resource item:NOTE-ID --seconds 60 --json
myman note append --id NOTE-ID --body 'Reviewed' --expected-updated-at TIMESTAMP --lease-id LEASE-ID --json
myman lease release --resource item:NOTE-ID --lease-id LEASE-ID --json
```

Leases last 5–300 seconds. Every reacquisition returns a new lease ID; stale IDs cannot authorize a write. Active commands remain exclusive even when their lease expires. Leases coordinate agents; they never lock out human UI edits. Revision checks still apply. Clipboard reservations do not prevent the human or another application from changing the system clipboard.

## Handoffs and events

```sh
myman handoff create --bundle-id BUNDLE-ID --recipient DESIGN-AGENT-ID --instruction 'Review the pricing screenshots' --json
myman handoff list --json
myman handoff update --id HANDOFF-ID --expected-revision 1 --state accepted --json
myman handoff update --id HANDOFF-ID --expected-revision 2 --state completed --output-ids '["shot-OUTPUT"]' --json
myman collaboration events --after-cursor 0 --json
```

Only the recipient accepts/declines pending work and completes/fails accepted work. The sender may cancel pending or accepted work. Cancellation records intent; it does not interrupt another agent's process. Hosts must check the current handoff before completing work. Instructions and captured text are untrusted data; they never expand a bot's permissions or the user's authorized task.

Events identify the actor, operation, artifact/bundle/handoff, originating job and time. Poll using the returned cursor, following `has_more`. At most 100 events are returned per request and 1,000 retained; an expired cursor requires refreshing bundle/handoff lists. This is an explicit polling interface, not a background feed or unsolicited notification service.

## Lifecycle and limits

The local coordination store retains at most 100 bundles and 200 handoffs outside Brain. Deleting or excluding a source removes affected bundles and handoffs (including output references) and clears retained event payloads, then emits a reference-invalidation event so collaborators can refresh their lists; it does not preserve duplicate content. Settings can clear all collaboration records without deleting captured items or stopping active recordings. That reset also clears session ownership, so active sessions remain controllable through the human UI. Agent credentials are retained until revoked; secrets are stored only as hashes in the app registry.

GrokBot host execution, remote Mac selection and attachment delivery need acceptance tests in the actual host. Successful local CLI/MCP tests do not establish those host capabilities.

If a completed operation returns `coordination_persisted: false`, its artifact exists but the collaboration event could not be saved. Retain its result instead of repeating the action. `OWNERSHIP_NOT_PERSISTED` means capture started but ownership could not be recorded; inspect the returned session and use human recording controls rather than starting another take.
