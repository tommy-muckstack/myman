import { discover, request } from './actions.mjs';

const required = ['brief.create', 'brief.read', 'brief.handoff', 'brief.submit', 'brief.review', 'brief.export'];

// Diagnose the actual host-selected Mac connection without capturing anything,
// changing grants or mistaking the bundled catalog for installed capabilities.
export async function checkWorkflow({ transport = request, machine = process.env.MYMAN_MACHINE_ID } = {}) {
  const live = await discover(undefined, { transport });
  const missing = required.filter(name => !live.actions.some(action => action.name === name));
  const checks = [
    { name: 'running_app', ok: live.live, fix: 'Open My Man on the Mac selected for local execution.' },
    { name: 'brief_actions', ok: live.live && missing.length === 0, fix: 'Update the My Man app and companion to a version advertising brief actions.' },
    { name: 'selected_mac', ok: !!machine && live.live && machine === live.machine?.id, fix: 'Set MYMAN_MACHINE_ID from My Man Settings → Agents on the intended Mac, or pass --machine.' },
    { name: 'named_agent', ok: live.live && !!live.agent?.id, fix: 'Configure this bot’s human-issued MYMAN_AGENT_TOKEN in the host secret environment.' },
    { name: 'library_access', ok: live.live && live.permissions?.enabled === true && live.permissions?.library === true && live.agent?.scopes?.includes('library') === true, fix: 'Enable library access for this named agent and globally in My Man Settings → Agents.' },
  ];
  const ok = checks.every(check => check.ok);
  return {
    ok, ready_for_brief_work: ok, checks, missing_actions: missing,
    app_version: live.app_version, machine: live.live ? live.machine ?? null : null,
    source: live.source, host_attachment_delivery: 'not_tested', host_dispatch: 'not_tested',
    next_step: ok ? 'Run a synthetic recorded brief through the worker and reviewer, and verify the requesting host actually delivers the finished attachment.' : 'Resolve the failed checks on the intended Mac, then run workflow check again.',
    ...(!ok ? { error: { code: 'WORKFLOW_SETUP_REQUIRED', message: checks.filter(check => !check.ok).map(check => check.fix).join(' ') } } : {}),
  };
}
