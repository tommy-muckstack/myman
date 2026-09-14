# My Man human and agent workflows

My Man 1.1.67 / companion 0.10.0 adds native Workflows and Recovery. Open it from the menu bar, Settings → Agents, or `myman workflow open`. Feature windows belong to My Man; there are no separate brief apps.

## Connect and hand off selected context

Workflows → Connection generates a ten-minute challenge for a named agent on this Mac. A successful `workflow handshake` proves the local command arrived. The user separately confirms the generated image appeared in the host. Local paths and successful CLI calls do not prove file delivery.

Choose **Prepare context for Bot** from any capture's menu, or **Choose captures to attach** in Connection. Select one to five captures of any kind. The export includes a Markdown context file and selected screenshot/video originals, within the host's attachment limits. It does not send them. Review the files, then attach them in Grok Bot. Local exports expire after an hour or source removal; recipient copies have their own lifecycle.

```sh
myman workflow context --ids '["note-ID","screenshot-ID","meeting-ID"]' --json
myman workflow templates --json
```

The starter Bot prompts are in `integrations/grok-bot/templates/`. Paste them into a Bot's instructions and use the host's Share Bot control when you want a public Bot template. A source-file link is not a Grok Bot share URL. Recipients must connect their own Mac and credentials.

## Capture and accessibility

**Choose Capture** provides a keyboard/VoiceOver window picker and numeric screen-area selection. VoiceOver users are routed here by Take Screenshot. Normal pointer area selection remains available. **Scrolling Capture** takes overlapping sections as you scroll downward; exclude fixed headers and keep some overlap visible. It refuses ambiguous matches and pauses at its image limit. Save keeps the assembled image; Cancel discards the session. It is not an automatic page scroller.

**Float as reference** keeps a saved screenshot above other windows, with opacity, Copy, drag and Close controls. Up to eight references can be open in My Man. The capture thumbnail also exposes actual buttons and stays available while VoiceOver is running.

Launcher actions are buttons; pointer hover is separate from keyboard focus. Arrow navigation shows an explicit outline without permanently highlighting the first item. Interface text can be enlarged in Settings. Status toasts announce their message through Accessibility. These are targeted improvements, not a certification that every legacy editor control meets every accessibility criterion.

```sh
myman capture scroll start --region '{"x":0,"y":0,"width":800,"height":600}' --json
myman capture scroll status --session-id ID --json
myman capture scroll stop --session-id ID --json
myman capture float --id screenshot-ID --json
```

## Meeting decisions and follow-ups

Workflows → Meeting decisions stores a topic, decision and exact supporting quote from one transcript turn. Timestamp and speaker come from the source. Decisions across meetings form a dated timeline. Source edits make old records visibly stale and ineligible for a follow-up until reviewed again. Agents may propose decisions; a human confirms them before drafting.

Speaker correction changes timestamped labels, preserves the original transcript, invalidates generated evidence and refreshes the Brain export. Existing user-written notes remain available and should be reviewed for old names. Select confirmed decisions and relevant captures to open an editable follow-up draft. Nothing is sent or assigned automatically.

```sh
myman decision create --source-id meeting-ID --expected-revision 3 --topic 'Launch' --text 'Launch Tuesday' --quote 'We agreed to launch the checkout on Tuesday.' --json
myman decision list --json
myman decision followup --ids '["decision-ID"]' --related-ids '["note-ID","screenshot-ID"]' --json
myman meeting speaker --id meeting-ID --expected-revision 3 --from 'Speaker 1' --to Alex --json
```

## Dictation delivery and recovery

Dictation saves its final text before insertion, checks the focused app/control, and reports verified, unverified or interrupted delivery. Secure/unsupported fields fall back to the clipboard. A mid-insertion focus change never triggers an automatic retry. Inspect the destination before pasting again.

Workflows → Dictation keeps recoverable text and delivery status. Human corrections feed the existing repeated-evidence vocabulary learning; agent corrections do not. Settings → Dictation provides app-specific writing styles and editable vocabulary. Latency analytics contain counts/status/duration, never transcript text.

```sh
myman dictation history --limit 20 --json
myman dictation correction --id ID --expected-text 'Current text' --text 'Corrected text' --json
myman dictation style --bundle-id com.example.editor --tone professional --json
```

## Activity and safe continuation

Workflows → Activity shows command state, source references, saved results and errors from durable receipts. Inspect sources/results or copy a continuation prompt. Supported long read/render jobs expose **Request stop**; completion remains visible in the final receipt. Recording/meeting/dictation sessions retain their existing owner-checked stop/cancel controls. Commands are never replayed automatically after interruption. Receipts retain up to seven days; deleted/excluded content clears their references/results.

## Optional expiring links

Configure a personal service in Workflows → Sharing; see `integrations/share-service/README.md`. Choose **Share** on a capture or **Publish for 24 hours** on a reviewed brief share page. Publishing is explicit and limited to 3 MB. Manage and revoke links in Sharing. Expiry and revocation are enforced by the server on every uncached read. Downloaded copies cannot be recalled.

Agent publishing has a separate disabled-by-default `sharing` permission and requires `confirm=true`. It cannot be enabled through an agent command. Named publishers can revoke only their own links. Deleting/excluding a source attempts revocation; a network failure remains visible for retry.
