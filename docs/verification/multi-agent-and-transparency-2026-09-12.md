# Multi-agent coordination and screenshot transparency verification

Candidate: companion/root/GrokBot plugin **0.8.0**, with **82 native actions** and **84 app MCP tools**. The separate Brain server retains its ten read-only retrieval tools. This is local implementation evidence, not a published app or marketplace approval.

## Checks

- **88 companion tests passed**, no skips. Source and packaged MCP servers, CLI routing, explicit Mac targeting and catalog/bundle checks passed.
- **177 native tests, six existing opt-in skips, zero failures.** The private background fixtures were explicitly enabled for this run. Existing skipped tests require private meeting fixtures or opt-in UI/model evaluation.
- Debug and universal Intel/Apple Silicon release builds passed.
- Native collaboration tests cover hashed credentials, revocation, wrong-Mac rejection, corrupt-registry failure, membership controls, stale bundle/handoff edits, handoff transitions, event delivery, durable reload, source deletion, lease fencing, session transfer and atomic task-version checks.
- An isolated app with synthetic data was exercised through the **packaged CLI and two independent packaged MCP clients**. Simultaneous bundle edits yielded one success and one conflict. Cross-agent job reads, unauthorized note creation, stale note/task edits and writes without the owner's lease were rejected. A handoff was accepted/completed and observed by its sender.
- The live test recorded only the synthetic app window with microphone/system audio off. A second agent could not stop it until the owner explicitly transferred the session. The former owner then lost control; the recipient finalized it and obtained the attachment. Test-created items were deleted through normal lifecycle actions.
- [Agent Settings visual check](multi-agent-settings.png): neutral fixture names, Gellix text, separate grants and credential controls. The panel scrolls; credentials are not present in this image.

## Background removal

The previous implementation relied only on photographic foreground detection and silently returned when it found no subject. Successful removal also automatically selected an opaque slate backdrop.

The new flat-background path finds a confident border color and clears only connected surrounding pixels, preserving enclosed same-colored content. Partially transparent edge samples are normalized before comparison, and boundary antialiasing is decontaminated where a nearby interior color provides sufficient evidence. Non-flat images still use Vision; unchanged/empty masks produce a clear UI message. Success selects a transparent backdrop, displays the existing checkerboard, and exports PNG alpha. Undo restores the prior image and backdrop.

Synthetic tests cover white/yellow surrounds, translucent border pixels, enclosed content, blank-canvas rejection, PNG alpha and undo. Both user-supplied screenshots also passed alpha/preservation checks and were visually inspected locally. **Those screenshots and their derived images are not committed.** Their opt-in test paths are supplied only through the environment.

Flat-color removal is conservative: it cannot infer an object boundary when an object and the surrounding background are indistinguishable. Photographic segmentation remains dependent on Vision. Failed separation leaves the original image intact.

## Scope and remaining host verification

Agent names are user-chosen. Personal agent naming was removed from repository examples, test fixtures and host-verification documentation; no Git history was rewritten.

Credentials scope app bridge actions, not filesystem access between processes sharing a macOS login. Bundles retain references/revisions, not frozen media snapshots. Leases expire and never block human UI edits. Handoffs/events are explicitly polled and never launch agents or send messages. Mac IDs verify the host-selected local connection; no remote listener or cross-Mac synchronization was added.

Actual GrokBot host discovery, approved remote execution and attachment delivery remain unverified here. The initial Cursor publisher application remains pending. Candidate 0.8.0 is prepared; no email, submission, push or app release was performed for this work.
