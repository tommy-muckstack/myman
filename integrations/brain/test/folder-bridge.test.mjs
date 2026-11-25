import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { run, exitCode } from '../app-cli.mjs';
import { catalog } from '../actions.mjs';
import { bridgeDirectory, bridgeRequested, bridgeStatus, bridgeTransport } from '../folder-bridge.mjs';
import { waitForJob } from '../actions.mjs';

// A stand-in for the app's side of the folder: what My Man writes when the
// bridge is on. No app, socket or personal data is involved.
async function folder({ enabled = true, beat = Date.now() / 1000 } = {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'myman-bridge-'));
  const directory = path.join(root, 'agent');
  for (const name of ['inbox', 'outbox', 'artifacts']) await mkdir(path.join(directory, name), { recursive: true });
  await writeFile(path.join(directory, 'manifest.json'), JSON.stringify({ version: 1, app_version: '9.9.9', enabled, grants: { enabled: true, capture: false }, actions: catalog.actions }));
  if (beat !== null) await writeFile(path.join(directory, 'heartbeat.json'), JSON.stringify({ epoch: beat, at: new Date(beat * 1000).toISOString() }));
  return { root, directory, answer: (id, body) => writeFile(path.join(directory, 'outbox', `${id}.json`), JSON.stringify({ id, ...body })), done: () => rm(root, { recursive: true, force: true }) };
}

test('the bridge is opt-in and its folder follows the Brain root', () => {
  assert.equal(bridgeRequested(undefined, {}), false);
  assert.equal(bridgeRequested(true, {}), true);
  assert.equal(bridgeRequested(undefined, { MYMAN_BRIDGE: '1' }), true);
  assert.equal(bridgeDirectory({ root: '/data/Brain', env: {} }), '/data/Brain/agent');
  assert.equal(bridgeDirectory({ env: { MYMAN_BRAIN_ROOT: '/mnt/brain' } }), '/mnt/brain/agent');
  assert.equal(bridgeDirectory({ root: '/data/Brain', env: { MYMAN_BRIDGE_DIR: '/mnt/agent' } }), '/mnt/agent');
});

test('status reports a missing folder, a disabled bridge and a stopped watcher', async () => {
  const missing = await bridgeStatus(path.join(tmpdir(), 'myman-bridge-none-' + randomUUID()));
  assert.equal(missing.ok, false); assert.equal(missing.problems[0].code, 'BRIDGE_NOT_FOUND');
  const off = await folder({ enabled: false });
  try { const status = await bridgeStatus(off.directory); assert.equal(status.writable, true); assert.deepEqual(status.problems.map(p => p.code), ['BRIDGE_DISABLED']); } finally { await off.done(); }
  const stopped = await folder({ beat: Date.now() / 1000 - 120 });
  try { const status = await bridgeStatus(stopped.directory); assert.equal(status.heartbeat.alive, false); assert.deepEqual(status.problems.map(p => p.code), ['APP_NOT_RUNNING']); } finally { await stopped.done(); }
  const live = await folder();
  try {
    const status = await bridgeStatus(live.directory);
    assert.equal(status.ok, true); assert.equal(status.app_version, '9.9.9'); assert.equal(status.heartbeat.alive, true);
    assert.deepEqual(await readdir(path.join(live.directory, 'inbox')), [], 'the write probe leaves nothing behind');
  } finally { await live.done(); }
});

test('a request is written whole and never sent when the bridge cannot answer', async () => {
  const live = await folder();
  try {
    const send = bridgeTransport(live.directory, { env: { MYMAN_AGENT_TOKEN: 'secret-token' } }), id = randomUUID();
    const first = await send({ method: 'invoke', id, action: 'app.status', arguments: {}, machine_id: 'mac-1' });
    assert.equal(first.job.state, 'running');
    assert.deepEqual(await readdir(path.join(live.directory, 'inbox')), [`${id}.json`]);
    const written = JSON.parse(await readFile(path.join(live.directory, 'inbox', `${id}.json`), 'utf8'));
    assert.deepEqual(Object.keys(written).sort(), ['action', 'args', 'created', 'credential', 'id', 'machine_id']);
    assert.equal(written.id, id); assert.equal(written.action, 'app.status'); assert.deepEqual(written.args, {});
    assert.ok(Math.abs(Date.parse(written.created) - Date.now()) < 5000);
    assert.equal((await send({ method: 'job', id })).job.state, 'running');
    await assert.rejects(send({ method: 'invoke', id: 'not-a-uuid', action: 'app.status', arguments: {} }), { code: 'INVALID_REQUEST' });
    await assert.rejects(send({ method: 'job', id: randomUUID() }), { code: 'JOB_NOT_FOUND' });
    await assert.rejects(send({ method: 'jobs' }), { code: 'UNSUPPORTED' });
  } finally { await live.done(); }
  const off = await folder({ enabled: false });
  try {
    await assert.rejects(bridgeTransport(off.directory, { env: {} })({ method: 'invoke', id: randomUUID(), action: 'app.status', arguments: {} }), { code: 'BRIDGE_DISABLED' });
    assert.deepEqual(await readdir(path.join(off.directory, 'inbox')), []);
  } finally { await off.done(); }
});

test('results map to the job shapes the CLI already understands', async () => {
  const live = await folder();
  try {
    const send = bridgeTransport(live.directory, { env: {} });
    const waiting = randomUUID(), saved = randomUUID(), failed = randomUUID(), list = randomUUID();
    await live.answer(waiting, { ok: false, pending: true, action: 'screenshot.capture', error: { code: 'AWAITING_USER', message: 'Waiting.' }, artifacts: [] });
    await live.answer(saved, { ok: true, action: 'screenshot.capture', result: { id: 'shot-1', path: '/Users/someone/shot.png' }, artifacts: [`artifacts/${saved}/shot.png`] });
    await live.answer(failed, { ok: false, action: 'note.create', error: { code: 'AGENT_DISABLED', message: 'Enable library access.', hint: 'A person turns it on.' }, artifacts: [] });
    await live.answer(list, { ok: true, action: 'screens.list', result: [{ id: '1' }], artifacts: [] });
    const pending = (await send({ method: 'job', id: waiting })).job;
    assert.equal(pending.state, 'running'); assert.equal(pending.awaiting_user, true);
    const done = (await send({ method: 'job', id: saved })).job;
    assert.equal(done.state, 'succeeded'); assert.deepEqual(done.result.artifacts, [`artifacts/${saved}/shot.png`]); assert.equal(done.result.id, 'shot-1');
    const broken = (await send({ method: 'job', id: failed })).job;
    assert.equal(broken.state, 'failed'); assert.equal(broken.error.code, 'AGENT_DISABLED'); assert.equal(broken.error.hint, 'A person turns it on.');
    assert.deepEqual((await send({ method: 'job', id: list })).job.result, [{ id: '1' }]);
  } finally { await live.done(); }
});

test('the CLI runs an action through the folder and reports a prompt that is still open', async () => {
  const live = await folder();
  try {
    const env = { MYMAN_BRIDGE: '1' };
    // Answer each request the way the app would, as soon as it appears.
    const serve = reply => { const timer = setInterval(async () => {
      for (const name of await readdir(path.join(live.directory, 'inbox')).catch(() => [])) {
        if (!name.endsWith('.json') || name.startsWith('.')) continue;
        const request = JSON.parse(await readFile(path.join(live.directory, 'inbox', name), 'utf8'));
        await live.answer(request.id, reply(request)); await rm(path.join(live.directory, 'inbox', name), { force: true });
      } }, 20); return () => clearInterval(timer); };
    let stop = serve(request => ({ ok: true, action: request.action, result: { launch_id: 'app', version: '9.9.9' }, artifacts: [] }));
    const status = await run(['invoke', 'app.status', '--bridge', '--root', live.root, '--json'], { env: {} }); stop();
    assert.equal(status.job.state, 'succeeded'); assert.equal(status.job.result.version, '9.9.9');
    const discovered = await run(['actions', 'app.status', '--root', live.root, '--json'], { env });
    assert.equal(discovered.live, true); assert.equal(discovered.app_version, '9.9.9');
    stop = serve(request => ({ ok: false, pending: true, action: request.action, error: { code: 'AWAITING_USER', message: 'Waiting.', hint: 'Read again.' }, artifacts: [] }));
    const held = await run(['screenshot', '--mode', 'agent', '--wait-timeout', '0.3', '--root', live.root, '--json'], { env }); stop();
    assert.equal(held.ok, false); assert.equal(held.pending, true); assert.equal(held.error.code, 'AWAITING_USER'); assert.equal(held.error.hint, 'Read again.');
    assert.equal(exitCode('AWAITING_USER'), 7); assert.equal(exitCode('BRIDGE_DISABLED'), 4); assert.equal(exitCode('USER_DENIED'), 3);
    await assert.rejects(run(['screenshot', '--bridge', '--root', live.root], { env: {} }), { code: 'INVALID_ARGUMENTS' });
  } finally { await live.done(); }
});

test('doctor names what a person must do before the bridge can work', async () => {
  const off = await folder({ enabled: false });
  try {
    const report = await run(['doctor', '--bridge', '--root', off.root, '--json'], { env: {}, access: undefined });
    assert.equal(report.ok, false); assert.equal(report.bridge.in_use, true); assert.equal(report.bridge.enabled, false);
    assert.equal(report.error.code, 'BRIDGE_DISABLED');
    assert.ok(report.next_steps.some(step => step.id === 'bridge_disabled' && step.for === 'person'));
    assert.equal(report.agent_access.source, 'bridge_manifest'); assert.equal(report.agent_access.agents_can_self_grant, false);
  } finally { await off.done(); }
});

test('a result that lands while the job is looked up is returned, never JOB_NOT_FOUND', async () => {
  const live = await folder();
  try {
    const transport = bridgeTransport(live.directory, { env: {} });
    const id = randomUUID();
    // The app wrote the result and removed the request between the bridge's two reads.
    await live.answer(id, { ok: true, action: 'screenshot.capture', result: { width: 10 }, artifacts: [] });
    const reply = await transport({ method: 'job', id });
    assert.equal(reply.job.state, 'succeeded'); assert.equal(reply.job.result.width, 10);
  } finally { await live.done(); }
});

test('a request that was taken but has no result yet reports running, and an unknown id still fails', async () => {
  const live = await folder();
  try {
    const transport = bridgeTransport(live.directory, { env: {} });
    const taken = randomUUID();
    await writeFile(path.join(live.directory, 'audit.log'), JSON.stringify({ at: 'now', event: 'request', id: taken, action: 'screenshot.capture' }) + '\n');
    assert.equal((await transport({ method: 'job', id: taken })).job.state, 'running');
    const unknown = randomUUID();
    await assert.rejects(transport({ method: 'job', id: unknown }), { code: 'JOB_NOT_FOUND' });
  } finally { await live.done(); }
});

test('job wait returns pending at the timeout and a finished job as soon as it lands', async () => {
  const id = randomUUID();
  const states = [{ job: { id, state: 'running' } }, { job: { id, state: 'running' } }, { job: { id, state: 'succeeded', result: { ok: 1 } } }];
  let clock = 0;
  const reply = await waitForJob(async () => states.shift() ?? { job: { id, state: 'running' } }, id, { timeoutMs: 10000, now: () => clock, sleep: async ms => { clock += ms; } });
  assert.equal(reply.job.state, 'succeeded');
  clock = 0;
  const pending = await waitForJob(async () => ({ job: { id, state: 'running' } }), id, { timeoutMs: 1000, now: () => clock, sleep: async ms => { clock += ms; } });
  assert.equal(pending.job.state, 'running');
});

test('the CLI job status and job wait commands report pending with the job id', async () => {
  const live = await folder();
  try {
    const env = { MYMAN_BRIDGE: '1' };
    const id = randomUUID();
    await writeFile(path.join(live.directory, 'inbox', `${id}.json`), '{}');
    const status = await run(['job', 'status', id, '--bridge', '--root', live.root, '--json'], { env: {} });
    assert.equal(status.job.state, 'running');
    const waited = await run(['job', 'wait', id, '--timeout', '0', '--bridge', '--root', live.root, '--json'], { env: {} });
    assert.equal(waited.ok, false); assert.equal(waited.pending, true); assert.equal(waited.job_id, id);
    assert.equal(waited.error.code, 'PROCESSING_TIMEOUT');
    await live.answer(id, { ok: false, pending: true, action: 'screenshot.capture', error: { code: 'AWAITING_USER', message: 'Waiting.' }, artifacts: [] });
    const awaiting = await run(['job', 'status', id, '--bridge', '--root', live.root, '--json'], { env: {} });
    assert.equal(awaiting.pending, true); assert.equal(awaiting.error.code, 'AWAITING_USER'); assert.equal(awaiting.job_id, id);
    await assert.rejects(run(['job', 'wait', id, '--timeout', '999', '--bridge', '--root', live.root], { env: {} }), { code: 'INVALID_ARGUMENTS' });
  } finally { await live.done(); }
});
