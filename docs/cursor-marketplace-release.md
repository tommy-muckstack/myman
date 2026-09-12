# Cursor marketplace release policy

Every releasable change to MyMan's agent package must prepare a new marketplace candidate and explicitly give Tommy the submit/notify step. Shipping the Mac app updates its local Brain/CLI; it does **not** update the Cursor listing or an installed Grok plugin. App and plugin versions are independent. Marketplace review and host activation are separate from local test results.

## Decide before merging or cutting a release

| Change | Required action |
| --- | --- |
| Root `plugin.json`, `mcp.json`, or `skills/**` | Bump the root plugin and prepare an update |
| `integrations/brain/**` MCP, CLI or committed bundle behavior | Bump the root plugin and changed companion package; prepare an update |
| `integrations/grok-bot/**` package or skill | Bump the root candidate and changed Grok package; prepare an update |
| Listing promises, privacy/network/permission claims, or agent CLI docs referenced by a skill | Bump the affected candidate and refresh submission copy |
| Intentional plugin release without a Mac app release | Prepare an update |
| Swift UI, capture UX, fonts or panels with no agent surface change | Normal app release only |
| Signing, notarization or Sparkle-only work | Normal app release only |
| Unrelated docs or release-policy-only instructions with no package/listing behavior change | No plugin bump; note the reason in the PR |

If scope is uncertain, plan a candidate and flag the uncertainty to Tommy in one line. Do not silently assume an app release updates the marketplace. The initial policy-only PR is exempt from a bump; this does not exempt future changes to listing promises.

## Prepare a candidate

1. Compare with the base of the release/PR. Use a patch bump for fixes, docs or packaging of the same agent surface; use a minor bump for new tools, skill behaviors or CLI workflows. Do not bump again if this release already contains the appropriate bump.
2. Update root `plugin.json` and, when changed, `integrations/grok-bot/plugin.json`. Keep companion `integrations/brain/package.json`, its lockfile and runtime version/discovery strings aligned when releasing that package. Check version assertions in tests. Root and Grok versions may differ only when one package is unchanged; label each separately in docs.
3. Refresh the candidate version, listing claims, date and **Submission status** in [marketplace-submission.md](marketplace-submission.md). Update package versions and actual smoke evidence in [grok-bot-marketplace.md](grok-bot-marketplace.md). Preserve the distinction between prepared, submitted/pending, accepted/live, and host-verified.
4. If companion sources changed, run `npm run bundle --prefix integrations/brain` and commit the generated resources. Verify with synthetic data:

   ```sh
   npm ci --ignore-scripts --prefix integrations/brain
   npm test --prefix integrations/brain
   npm run check-bundle --prefix integrations/brain
   ```

   Run relevant native checks when the app/CLI bridge changes. Never commit personal Brain data, real capture content or credentials.
5. Open a PR to `main`, for example `Prepare myman-brain X.Y.Z Cursor marketplace candidate`, or include the candidate in the related implementation PR. Explain the trigger, version and verification. Include the notification block below in the PR or after merge.

## Submit or notify Cursor

Check the recorded submission status first. An initial publisher application for this org/repo was submitted on **2026-09-12** and is **awaiting review**, per Tommy's confirmation. This is not a live listing. While it is pending, prefer an update email to `marketplace-publishing@cursor.com` with org `@muckstack`, repo and new version. Do not file a duplicate application unless Tommy explicitly requests it.

Always surface the next step to Tommy. Preparing a candidate does not authorize sending email or submitting a form. Do not submit from CI. If Tommy explicitly asks for browser submission, use the fields below and record the actual confirmation text/date in the listing doc. If he authorizes an update email, record the sent update separately from marketplace acceptance.

| Publisher field | Value |
| --- | --- |
| Organization / handle | MuckStack, LLC / `muckstack` |
| Email | `tommy@muckstack.com` |
| Website | `https://muckstack.com` |
| Repository | `https://github.com/tommy-muckstack/myman` |
| My Man logo | `https://raw.githubusercontent.com/tommy-muckstack/myman/main/assets/icon-256.png` |

Use the My Man logo above, not the GitHub organization avatar. The first application used the wrong avatar; Tommy chose to wait for review rather than send a logo-only correction. Carry the correct logo into the next authorized update.

Paste-ready notification template (replace `X.Y.Z` with the prepared version):

```text
Cursor marketplace update ready: myman-brain X.Y.Z
Repo: https://github.com/tommy-muckstack/myman
Logo (if asked): https://raw.githubusercontent.com/tommy-muckstack/myman/main/assets/icon-256.png
Listing: docs/marketplace-submission.md
Publish: https://cursor.com/marketplace/publish
If a prior application is still In Review: email marketplace-publishing@cursor.com with org @muckstack + new version instead of filing a duplicate application.
```

Policy-only dry run: no package behavior changed, so the existing candidate version is retained. The initial application stays pending, no email/form is sent, and this notification is a template rather than a claim that a new candidate was submitted. For a later agent-surface change, the completed PR must include the actual new version and this submit/notify step.

Signing, notarization and app release ownership remain governed by [CONTRIBUTING.md](../CONTRIBUTING.md). Grok still needs approved Local Computer execution on the user's Mac; marketplace preparation does not grant it access.
