import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, lstat, readlink, rm, readFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { plan, run, unwrap, exitCode } from '../app-cli.mjs';
import { catalog } from '../actions.mjs';
import * as access from '../agent-access.mjs';
import { errorResult } from '../tools.mjs';
import { BrainError } from '../brain.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const mac = { platform: () => 'darwin' };
// A fake `defaults` that stores bool preferences in memory.
function fakeDefaults(initial = {}, { running = false } = {}) {
  const store = new Map(Object.entries(initial)), writes = [];
  return {
    store, writes,
    platform: () => 'darwin',
    pgrep: async () => running,
    defaults: async args => {
      if (args[0] === 'read') { if (!store.has(args[2])) throw new Error('does not exist'); return store.get(args[2]) ? '1\n' : '0\n'; }
      if (args[0] === 'write') { assert.equal(args[1], access.BUNDLE_ID); assert.equal(args[3], '-bool'); writes.push(args[2]); store.set(args[2], args[4] === 'true'); return ''; }
      throw new Error('unexpected defaults call');
    },
  };
}
const tty = { isTTY: true }, pipe = { isTTY: false };
const io = (answer, extra = {}) => ({ stdin: tty, stdout: tty, stderr: { write() {} }, ask: async () => answer, env: { PATH: '/usr/bin' }, ...extra });

test('grant requires a person: refused for agent environments and non-interactive terminals, with nothing written', async () => {
  for (const [name, options] of [
    ['agent token', io('grant capture', { env: { MYMAN_AGENT_TOKEN: 'secret', PATH: '/usr/bin' } })],
    ['machine id', io('grant capture', { env: { MYMAN_MACHINE_ID: 'mac', PATH: '/usr/bin' } })],
    ['CI', io('grant capture', { env: { CI: 'true', PATH: '/usr/bin' } })],
    ['piped stdin', io('grant capture', { stdin: pipe })],
    ['piped stdout', io('grant capture', { stdout: pipe })],
  ]) {
    const deps = fakeDefaults();
    await assert.rejects(access.change('grant', ['capture'], { deps, ...options }), error => {
      assert.equal(error.code, 'HUMAN_REQUIRED', name);
      assert.match(error.hint, /agents grant capture/);
      return true;
    });
    assert.deepEqual(deps.writes, [], name);
  }
});

test('grant needs the exact typed confirmation naming what is granted', async () => {
  for (const wrong of ['', 'yes', 'y', 'grant', 'grant all', 'GRANT CAPTURE', 'grant capture markup']) {
    const deps = fakeDefaults();
    await assert.rejects(access.change('grant', ['capture'], { deps, ...io(wrong) }), { code: 'CANCELLED' });
    assert.deepEqual(deps.writes, [], wrong);
  }
  const deps = fakeDefaults();
  const shown = [];
  const result = await access.change('grant', ['capture'], { deps, ...io('grant capture', { stderr: { write: text => shown.push(text) } }) });
  assert.deepEqual(result.granted, ['capture']);
  assert.deepEqual(deps.writes, ['agentCaptureEnabled']);
  assert.equal(result.grants.capture, true);
  assert.equal(result.grants.markup, false);
  assert.match(shown.join(''), /type exactly: grant capture/);
  assert.match(shown.join(''), /Capture screenshots without the picker/);
});

test('"all" names each group in its confirmation and never includes control, calendar, people or the master switch', async () => {
  const deps = fakeDefaults();
  await assert.rejects(access.change('grant', ['all'], { deps, ...io('grant all') }), { code: 'CANCELLED' });
  const result = await access.change('grant', ['all'], { deps, ...io('grant capture markup recording library sharing') });
  assert.deepEqual(result.granted, ['capture', 'markup', 'recording', 'library', 'sharing']);
  assert.deepEqual(deps.writes.sort(), ['agentCaptureEnabled', 'agentLibraryEnabled', 'agentMarkupEnabled', 'agentRecordingEnabled', 'agentSharingEnabled']);
  for (const name of ['control', 'calendar_read', 'calendar_write', 'calendar_propose', 'people_read', 'scheduling_parse', 'enabled']) {
    await assert.rejects(access.change('grant', [name], { deps: fakeDefaults(), ...io('x') }), { code: 'INVALID_ARGUMENTS' }, name);
  }
  await assert.rejects(access.change('grant', ['bogus'], { deps: fakeDefaults(), ...io('x') }), { code: 'INVALID_ARGUMENTS' });
});

test('revoke only narrows access and works without a terminal', async () => {
  const deps = fakeDefaults({ agentCaptureEnabled: true, agentLibraryEnabled: true });
  const result = await access.change('revoke', ['capture'], { deps, stdin: pipe, stdout: pipe, env: { MYMAN_AGENT_TOKEN: 'x', PATH: '/usr/bin' } });
  assert.deepEqual(result.revoked, ['capture']);
  assert.equal(result.grants.capture, false);
  assert.equal(result.grants.library, true);
});

test('status reads preferences without writing, and works while the app is closed', async () => {
  const deps = fakeDefaults({ agentCaptureEnabled: true });
  const status = await access.status(deps, { PATH: '/usr/bin' });
  assert.equal(status.app_running, false);
  assert.equal(status.grants.capture, true);
  assert.equal(status.grants.enabled, true); // master defaults on
  assert.deepEqual(status.disabled, ['markup', 'recording', 'library', 'sharing']);
  assert.deepEqual(deps.writes, []);
  assert.ok(status.next_steps.some(step => step.id === 'launch_app'));
  assert.ok(!status.next_steps.some(step => step.id === 'grant_capture'));
});

test('grant is unsupported off macOS and writes nothing', async () => {
  const deps = { ...fakeDefaults(), platform: () => 'linux' };
  await assert.rejects(access.change('grant', ['capture'], { deps, ...io('grant capture') }), { code: 'unsupported_on_platform' });
  await assert.rejects(access.status(deps), { code: 'unsupported_on_platform' });
  assert.deepEqual(deps.writes, []);
});

test('CLI routing has no bypass flags and keeps grant out of the action catalog and invoke', async () => {
  assert.deepEqual(await plan(['agents', 'grant', 'capture']), { type: 'agents', sub: 'grant', names: ['capture'] });
  assert.deepEqual(await plan(['agents', 'grant', 'capture', 'markup']), { type: 'agents', sub: 'grant', names: ['capture', 'markup'] });
  for (const flag of ['--yes', '-y', '--confirm', '--force', '--non-interactive', '--token=x']) {
    await assert.rejects(plan(['agents', 'grant', 'capture', flag]), error => error.code === 'INVALID_ARGUMENTS' || error.code?.startsWith('ERR_PARSE_ARGS'), flag);
  }
  await assert.rejects(plan(['agents', 'grant']), { code: 'INVALID_ARGUMENTS' });
  await assert.rejects(plan(['agents', 'enable', 'capture']), { code: 'INVALID_ARGUMENTS' });
  assert.ok(!catalog.actions.some(action => /grant|install[._-]cli|^agents?\.(enable|grant)/i.test(action.name)), 'no catalog action can grant access');
  for (const action of catalog.actions) assert.ok(!Object.keys(action.inputSchema.properties ?? {}).some(key => /^agent(_|[A-Z])?(capture|markup|recording|library|sharing)/i.test(key) || /grant/.test(key)), action.name);
  // invoke can only reach catalog actions; the app rejects anything else.
  const invoked = await plan(['invoke', 'agents.grant', '{"group":"capture"}']);
  assert.equal(invoked.type, 'action');
  await assert.rejects(run(['invoke', 'agents.grant', '{}'], { invoke: undefined, request: async () => ({ ok: true, result: catalog }) }), { code: 'UNSUPPORTED_ACTION' });
});

test('the grant command is not importable from the MCP server', async () => {
  const source = await readFile(path.join(here, '../app-server.mjs'), 'utf8');
  assert.ok(!/agent-access/.test(source) && !/\bchange\(/.test(source));
  assert.match(source, /Never enable permissions/);
});

test('the Swift preference keys match what the Terminal command writes', async () => {
  const swift = await readFile(path.join(here, '../../../src/Core/AgentConsent.swift'), 'utf8');
  for (const [group, { key }] of Object.entries(access.GRANTABLE)) assert.match(swift, new RegExp(`"${group}": "${key}"`), group);
  const build = await readFile(path.join(here, '../../../scripts/build-direct.sh'), 'utf8');
  assert.match(build, new RegExp(`BUNDLE_ID="${access.BUNDLE_ID.replaceAll('.', '\\.')}"`));
});

test('AGENT_DISABLED errors carry a stable code, a hint and the exact human command, in JSON', () => {
  const env = { PATH: '/usr/bin' };
  const capture = access.annotateError({ code: 'AGENT_DISABLED', message: 'Enable capture access in My Man Settings → Agents for this action.' }, { env, platform: 'darwin' });
  assert.equal(capture.code, 'AGENT_DISABLED');
  assert.equal(capture.human_command, '"/Applications/My Man.app/Contents/Resources/myman" agents grant capture');
  assert.deepEqual(capture.groups, ['capture']);
  assert.equal(capture.agent_may_self_grant, false);
  assert.match(capture.hint, /A person must allow capture access/);
  assert.match(capture.hint, /agents open/);
  assert.match(capture.hint, /doctor --json/);
  const onPath = access.annotateError({ code: 'AGENT_DISABLED', message: 'Enable markup access in My Man Settings → Agents for this action.' }, { env: { PATH: path.dirname(process.execPath) }, platform: 'darwin' });
  assert.equal(onPath.human_command, '"/Applications/My Man.app/Contents/Resources/myman" agents grant markup'); // no myman on PATH here
  const master = access.annotateError({ code: 'AGENT_DISABLED', message: 'Local app actions are disabled in Settings → Agents.' }, { env, platform: 'darwin' });
  assert.match(master.hint, /Allow local app commands/);
  assert.ok(!/agents grant/.test(master.hint), 'the master switch is Settings-only');
  const calendar = access.annotateError({ code: 'AGENT_DISABLED', message: 'Enable calendar_read and calendar_write in My Man Settings → Agents.' }, { env, platform: 'darwin' });
  assert.equal(calendar.human_command, undefined);
  assert.deepEqual(calendar.groups, ['calendar_read', 'calendar_write']);
  assert.match(calendar.hint, /agents open/);
  const json = JSON.parse(JSON.stringify(capture));
  assert.equal(json.code, 'AGENT_DISABLED');
  assert.equal(exitCode(json.code), 4);
});

test('failed jobs, raw invoke replies and thrown errors all carry the hint', async () => {
  const failed = { ok: true, job: { id: 'j', state: 'failed', error: { code: 'AGENT_DISABLED', message: 'Enable capture access in My Man Settings → Agents for this action.' } } };
  const wrapped = unwrap(failed, undefined, { platform: 'darwin' });
  assert.equal(wrapped.ok, false);
  assert.match(wrapped.error.hint, /agents grant capture/);
  assert.equal(exitCode(wrapped.error.code), 4);
  const viaRun = await run(['screenshot', '--mode', 'agent', '--wait'], { platform: 'darwin', invoke: async () => failed });
  assert.match(viaRun.error.hint, /agents grant capture/);
  const viaWindows = await run(['windows', 'list'], { platform: 'darwin', invoke: async () => failed });
  assert.equal(viaWindows.error.code, 'AGENT_DISABLED');
  const raw = await run(['invoke', 'screenshot.capture', '{}'], { platform: 'darwin', invoke: async () => failed });
  assert.match(raw.job.error.hint, /agents grant capture/);
  const thrown = errorResult(new BrainError('AGENT_DISABLED', 'Enable library access in My Man Settings → Agents for this action.'), { platform: 'darwin' });
  assert.match(thrown.error.hint, /agents grant library/);
  assert.equal(errorResult(new BrainError('APP_NOT_RUNNING', 'Open the app.'), { platform: 'darwin' }).error.launch_command, 'open -a "My Man"');
  // Other errors are untouched.
  assert.deepEqual(errorResult(new BrainError('NOT_FOUND', 'x'), { platform: 'darwin' }), { error: { code: 'NOT_FOUND', message: 'x' } });
});

test('doctor with the app closed says so, gives the launch command and reads grants from preferences', async () => {
  const deps = {
    platform: 'darwin', env: { PATH: '/usr/bin' }, accessDeps: fakeDefaults({ agentActionsEnabled: true }, { running: false }),
    request: async () => { throw new BrainError('APP_NOT_RUNNING', 'Open the updated My Man app, then retry.'); },
  };
  const report = await run(['doctor', '--root', await mkdtemp(path.join(tmpdir(), 'man-doctor-'))], deps);
  assert.equal(report.ok, false);
  assert.equal(report.app.running, false);
  assert.equal(report.app.process_running, false);
  assert.equal(report.app.launch_command, 'open -a "My Man"');
  assert.match(report.app.error.hint, /open -a "My Man"/);
  assert.equal(report.agent_access.source, 'preferences');
  assert.equal(report.agent_access.agents_can_self_grant, false);
  assert.deepEqual(report.agent_access.disabled, ['capture', 'markup', 'recording', 'library', 'sharing']);
  const ids = report.next_steps.map(step => step.id);
  assert.deepEqual(ids, ['launch_app', 'grant_capture', 'grant_markup', 'grant_recording', 'grant_library', 'grant_sharing', 'install_cli']);
  for (const step of report.next_steps.filter(step => step.id.startsWith('grant_'))) {
    assert.match(step.run, /agents grant (capture|markup|recording|library|sharing)$/);
    assert.equal(step.for, 'person');
    assert.match(step.alternative, /agents open/);
  }
  assert.equal(report.cli.on_path, false);
  assert.equal(report.cli.path, '/Applications/My Man.app/Contents/Resources/myman');
  assert.match(report.cli.install_command, /install-cli$/);
  assert.match(report.agent_access.human_command, /agents grant capture markup recording library sharing$/);
  assert.equal(exitCode(report.error.code), 6);
});

test('doctor distinguishes a running-but-unreachable app and reports a healthy app with grants on', async () => {
  const stuck = await run(['doctor', '--root', await mkdtemp(path.join(tmpdir(), 'man-doctor-'))], {
    platform: 'darwin', env: { PATH: '/usr/bin' }, accessDeps: fakeDefaults({}, { running: true }),
    request: async () => { throw new BrainError('APP_NOT_RUNNING', 'x'); },
  });
  assert.equal(stuck.app.process_running, true);
  assert.match(stuck.app.error.hint, /running but the CLI cannot reach/);
  assert.ok(stuck.next_steps.some(step => step.id === 'restart_app'));
  assert.ok(!stuck.next_steps.some(step => step.id === 'launch_app'));

  const native = { ok: true, job: { id: 'd', state: 'succeeded', result: { permissions: { screen_recording: true, accessibility: true }, agents: { enabled: true, capture: true, markup: true, recording: false, library: true, sharing: true } } }, launch_id: 'l' };
  const healthy = await run(['doctor', '--root', await mkdtemp(path.join(tmpdir(), 'man-doctor-'))], { platform: 'darwin', env: { PATH: path.dirname(process.execPath) }, invoke: async () => native });
  assert.equal(healthy.app.ok, true);
  assert.equal(healthy.agent_access.source, 'running_app');
  assert.deepEqual(healthy.agent_access.disabled, ['recording']);
  assert.deepEqual(healthy.next_steps.map(step => step.id), ['grant_recording', 'install_cli']);
  const off = await run(['doctor', '--root', await mkdtemp(path.join(tmpdir(), 'man-doctor-'))], { platform: 'darwin', env: { PATH: '/usr/bin' }, invoke: async () => ({ ...native, job: { ...native.job, result: { permissions: { screen_recording: false }, agents: { enabled: false, capture: true } } } }) });
  assert.ok(off.next_steps.some(step => step.id === 'enable_commands' && !/agents grant/.test(step.run)));
  assert.ok(off.next_steps.some(step => step.id === 'screen_recording'));
});

test('doctor --plain prints each next step as a copy-pasteable line', async () => {
  const report = await run(['doctor', '--plain', '--root', await mkdtemp(path.join(tmpdir(), 'man-doctor-'))], {
    platform: 'darwin', env: { PATH: '/usr/bin' }, accessDeps: fakeDefaults({}, { running: false }),
    request: async () => { throw new BrainError('APP_NOT_RUNNING', 'x'); },
  });
  assert.match(report.plain, /open -a "My Man"/);
  assert.match(report.plain, /agents grant capture\n/);
  assert.match(report.plain, /✗ capture/);
  assert.match(report.plain, /one go/);
});

test('install-cli links ~/.local/bin/myman, is idempotent and never overwrites', async t => {
  const home = await mkdtemp(path.join(tmpdir(), 'man-home-')), app = await mkdtemp(path.join(tmpdir(), 'man-app-'));
  t.after(() => Promise.all([rm(home, { recursive: true, force: true }), rm(app, { recursive: true, force: true })]));
  const helper = path.join(app, 'myman');
  await writeFile(helper, '#!/bin/sh\n'); await chmod(helper, 0o755);
  const env = { MYMAN_HELPER_PATH: helper, PATH: '/usr/bin' };
  const first = access.installCli({ env, home, platform: 'darwin' });
  assert.equal(first.installed, true);
  assert.equal(await readlink(path.join(home, '.local/bin/myman')), helper);
  assert.equal(first.directory_on_path, false);
  assert.match(first.next, /\.zshenv/);
  const again = access.installCli({ env, home, platform: 'darwin' });
  assert.equal(again.installed, false);
  assert.equal(again.already_installed, true);
  const other = path.join(home, '.local/bin/myman');
  await rm(other); await writeFile(other, 'mine');
  assert.throws(() => access.installCli({ env, home, platform: 'darwin' }), { code: 'CLI_PATH_CONFLICT' });
  assert.equal(await readFile(other, 'utf8'), 'mine');
  assert.throws(() => access.installCli({ env: { MYMAN_HELPER_PATH: path.join(app, 'missing') }, home, platform: 'darwin' }), { code: 'HELPER_NOT_FOUND' });
  assert.throws(() => access.installCli({ env, home, platform: 'linux' }), { code: 'unsupported_on_platform' });
});

test('real process: grant refuses without a terminal, even with a piped confirmation, and prints JSON', () => {
  const cli = path.join(here, '../cli.mjs');
  const result = spawnSync(process.execPath, [cli, 'agents', 'grant', 'capture', '--json'], { input: 'grant capture\n', encoding: 'utf8', env: { ...process.env, MYMAN_AGENT_TOKEN: '' } });
  const out = JSON.parse(result.stdout);
  assert.equal(out.ok, false);
  assert.ok(['HUMAN_REQUIRED', 'unsupported_on_platform'].includes(out.error.code), out.error.code);
  assert.notEqual(result.status, 0);
  const yes = spawnSync(process.execPath, [cli, 'agents', 'grant', 'capture', '--yes'], { encoding: 'utf8' });
  assert.equal(JSON.parse(yes.stdout).error.code, 'INVALID_ARGUMENTS');
});

test('help documents the person-only commands and the exact CLI path', async () => {
  const { help } = await run(['--help']);
  assert.match(help, /agents grant\|revoke/);
  assert.match(help, /No agent command, MCP tool or --flag can enable them/);
  assert.match(help, /\/Applications\/My Man\.app\/Contents\/Resources\/myman/);
  assert.match(help, /open -a "My Man"/);
});
