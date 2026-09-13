# Recorded briefs and visual proof

Companion/plugin candidate **0.9.0** adds saved recorded briefs, explicit worker/reviewer assignments, evidence-backed review, two reusable recipes, and portable share-page export. Discover the installed app's actions before using them. My Man 1.1.65 does not include these new brief actions.

Open **Settings → Agents → Recorded briefs and workflow templates**, or choose **Make agent brief** from a recording's library menu. Choose the source recording, outcome and acceptance criteria. Add optional key moments in seconds; otherwise context extraction samples four frames. My Man stores source IDs and revisions, not duplicate recordings or transcripts.

Assign two different named agents with library access. Copy the handoff into the requesting host. My Man persists the assignment; GrokBot must dispatch the work using each bot's configured identity. This does not create Bots or grant access. Existing capture/markup/recording grants apply to any additional tools the workflow needs.

## bug-fix

**Watch this bug and fix it.** Record the problem and describe the expected behavior. The worker uses the host's development tools to reproduce and fix it. It saves visual proof in My Man, such as an annotated comparison and a short demonstration. The independent reviewer replays the scenario, checks relevant regressions, and addresses every acceptance criterion. A screenshot difference alone does not prove a functional fix.

Starter prompt:

> Use My Man on my selected Mac to turn this bug recording into a brief. Help me define the expected behavior and acceptance criteria. Have my chosen developer bot fix it and save a before/after comparison or demonstration. Have a different reviewer check the result against the recording and cite evidence for every criterion. Return the finished proof here.

## launch-kit

**Turn this demo into a launch kit.** The editor selects a useful segment, exports a captioned clip, creates clean screenshots and saves draft launch copy as a note. The reviewer checks the captions/copy against the demonstration and inspects exported visuals and audio for the intended audience. The initial role pair is editor/reviewer; the host may involve additional copywriting specialists within the user's request.

Starter prompt:

> Use My Man on my selected Mac to turn this demo into a launch kit: a captioned clip, screenshots and draft launch copy. Make a brief with the audience and acceptance criteria. Have my chosen editor bot prepare the assets, then a separate reviewer check their accuracy and suitability. Return the finished files here. Publishing is a separate step.

## Setup and discovery

Run on the registered Mac, with each agent's credential in the host's secret environment:

```sh
myman workflow check --json
myman workflow templates --json
```

`workflow check` verifies the live app, brief actions, named identity, explicit Mac ID and library grants. It never captures content or changes permissions. `ready_for_brief_work: true` establishes those local prerequisites only. `host_dispatch` and `host_attachment_delivery` remain `not_tested`; verify them in the actual GrokBot conversation. MCP hosts use `myman_app_workflow_check` and `myman_app_workflow_templates`.

The human sets `MYMAN_MACHINE_ID` from My Man Settings and configures each `MYMAN_AGENT_TOKEN` through the host's secure environment. The CLI also accepts `--machine ID`. Existing same-login filesystem access is outside the agent credential boundary.

## Executable flow

Use IDs returned by live discovery/library lookup and retain each returned revision. The names below denote placeholders, not resources to create implicitly.

```sh
myman brief create --title 'Checkout behavior' --recipe bug-fix \
  --outcome 'Checkout should create exactly one order' \
  --criteria '["Checkout confirms one order","Repeated clicks do not duplicate orders"]' \
  --source-ids '["recording-ID"]' --frame-times '[1,3]' --json
myman brief handoff --id BRIEF-ID --expected-revision 1 \
  --worker WORKER-ID --reviewer REVIEWER-ID --json
```

Dispatch the brief ID through the host to the assigned worker. With the worker's identity:

```sh
myman brief read --id BRIEF-ID --include-context --json
myman brief submit --id BRIEF-ID --expected-revision 2 \
  --output-ids '["shot-PROOF","note-TEST-RESULTS"]' \
  --summary 'Checkout completes once; proof and test results attached.' --json
```

`include_context` returns the original recording's transcript (up to 50,000 characters with a truncation flag), source references and timestamped frames/contact sheet. Transcript words have no timing map; cite frame `actual_time` for visual claims, and do not fabricate transcript timestamps. If text is empty or pending, inspect readiness or proceed explicitly with visual-only context when that meets the user's request. Temporary frames expire after one hour or on source deletion/exclusion.

Use existing `capture compare` plus `capture import` to save the generated comparison as a library item before submission. A temporary preview path is not a durable evidence ID. New video exports already return saved recording IDs. At least one submitted item must be a screenshot or recording, and source IDs themselves cannot be submitted as new evidence.

Dispatch to the reviewer. With the reviewer's identity, first read the brief and inspect the original context and submitted results. Then:

```sh
myman brief review --id BRIEF-ID --expected-revision 3 --checks \
  '[{"criterion":0,"passed":true,"evidenceIDs":["shot-PROOF"],"note":"Observed the confirmation in the submitted demonstration."},{"criterion":1,"passed":true,"evidenceIDs":["note-TEST-RESULTS"],"note":"Ran the repeated-click regression and checked the recorded order count."}]' --json
```

Every zero-based criterion must appear once. Passing checks require submitted evidence IDs and an explanation. A failed check yields `changes_requested`; the owner can hand the work back with the current revision. Sources/results that change block submission, review and export; the owner uses `brief refresh` to accept current source revisions and restart from draft. Refresh clears assignments and prior submission/review metadata. A reviewed state records the reviewer's judgment, not an automated guarantee of correctness.

`brief open --id BRIEF-ID` opens the native workspace. `brief list` shows only briefs available to that identity. Deleting/excluding a source or submitted result removes associated briefs. `brief delete --id BRIEF-ID --expected-revision N --confirm` removes metadata without deleting captures.

## Share only selected results

After review, use **Prepare share page** in the workspace. Write a public title/summary and explicitly select the finished screenshots or video. Inspect visuals and video audio. The original brief, its outcome/criteria/transcript, credentials, agent names and source paths are not automatically included.

The owner can also export through CLI when the user's request authorizes the selected public content:

```sh
myman brief export --id BRIEF-ID --expected-revision 4 \
  --public-title 'Checkout fixed' --public-summary 'A short demonstration of the corrected flow.' \
  --output-ids '["shot-PROOF"]' --confirm --json
```

The returned attachment is self-contained HTML with embedded media, a reusable starter prompt and a workflow link. No tracking scripts or remote media are loaded. Up to four visuals and 22 MiB of combined media are supported; screenshots are re-encoded with a maximum dimension of 1,800 pixels. Video exports must already be short enough. The temporary page expires in one hour; the human can save a durable copy from the UI. Saved/exported copies are independent of later library deletion. Uploading or sending a page is performed separately by the requesting host within the user's instructions.

A real public Bot share URL copied from GrokBot can be provided with `--bot-url`; it adds a **Use this bot** link. Without one, the page links to the recipe. My Man does not fabricate a host template ID or claim that a public template has been created. Share URLs must use HTTPS on x.ai or grok.com; existence and host acceptance still need to be checked.

## GrokBot acceptance and template sharing

In GrokBot, load the skill-only package from `integrations/grok-bot`, select the registered Mac and run the synthetic recipe above with two separately configured identities. Confirm the original video frames are visible, assignments reach the right Bots, and the final file arrives as an actual attachment. Test Mac offline/denied execution, stale revisions and a missing grant as well.

Save the successful role instructions as Bots/skills, then use GrokBot's own **Share a Bot** flow to create public template links. Review shared configuration so it contains generic instructions rather than personal source IDs, private URLs, credentials, attachments or account-specific agent names. The resulting Bot copy still needs the recipient's own My Man setup and permissions. [Official Bot sharing instructions](https://docs.x.ai/grok-bot/bots).

The development environment can exercise native CLI/MCP clients but has no GrokBot execution API. A local pass is not a GrokBot installation, dispatch or attachment-delivery pass. Record actual host evidence separately before promoting templates as host-verified.
