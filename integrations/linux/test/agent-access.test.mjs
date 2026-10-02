import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { linuxNextSteps } from '../../brain/agent-access.mjs';
const exec = promisify(execFile), here = path.dirname(fileURLToPath(import.meta.url));

async function cli(entry, args, env) {
  let result;
  try { result = await exec(process.execPath, [path.resolve(here, '..', entry), ...args, '--json'], { env }); } catch (error) { result = error; }
  return JSON.parse(result.stdout);
}
for (const entry of ['cli.mjs', 'bundle/cli.mjs']) {
  test(`Linux keeps grants owner-edited: hints, unsupported_on_platform and next_steps (${entry})`, { skip: process.platform !== 'linux' }, async t => {
    const base = await mkdtemp(path.join(tmpdir(), 'myman-access-'));
    t.after(() => rm(base, { recursive: true, force: true }));
    const env = { ...process.env, MYMAN_BRAIN_ROOT: path.join(base, 'Brain'), XDG_CONFIG_HOME: path.join(base, 'config'), XDG_STATE_HOME: path.join(base, 'state') };
    delete env.MYMAN_AGENT_TOKEN; delete env.MYMAN_MACHINE_ID;
    await mkdir(env.MYMAN_BRAIN_ROOT, { mode: 0o700 });
    await mkdir(path.join(env.XDG_CONFIG_HOME, 'myman'), { recursive: true, mode: 0o700 });

    const denied = await cli(entry, ['library', 'recent'], env);
    // Library reads may need git; any grant failure must carry a stable code and a human hint.
    const blocked = await cli(entry, ['note', 'create', '--body', 'x'], env);
    assert.equal(blocked.error.code, 'AGENT_DISABLED');
    assert.match(blocked.error.hint, /Agents cannot enable this/);
    assert.match(blocked.error.hint, /agents\.json/);
    assert.match(blocked.error.hint, /no command that grants access on Linux/);
    assert.equal(blocked.error.agent_may_self_grant, false);
    assert.ok(denied);

    for (const args of [['agents', 'grant', 'capture'], ['agents', 'status'], ['agents', 'open'], ['install-cli']]) {
      const result = await cli(entry, args, env);
      assert.equal(result.ok, false, args.join(' '));
      assert.equal(result.error.code, 'unsupported_on_platform', args.join(' '));
    }
    const doctor = await cli(entry, ['doctor'], env);
    assert.equal(doctor.next_steps[0].id, 'edit_grants');
    assert.equal(doctor.next_steps[0].for, 'person');
    assert.match(doctor.next_steps[0].edit, /"enabled": true/);
    assert.match(doctor.next_steps[0].file, /agents\.json$/);
  });
}

test('linuxNextSteps lists only what is still off', () => {
  assert.deepEqual(linuxNextSteps({ enabled: true, capture: true, markup: true, recording: true, library: true }), []);
  const [step] = linuxNextSteps({ enabled: true, capture: true, markup: false, recording: false, library: true }, '/home/p/.config/myman/agents.json');
  assert.equal(step.edit, '{"version": 1, "grants": {"enabled": true, "markup": true, "recording": true}}');
  assert.equal(step.file, '/home/p/.config/myman/agents.json');
});
