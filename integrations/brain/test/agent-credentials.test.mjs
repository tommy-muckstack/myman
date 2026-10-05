import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { readFileSync, existsSync, statSync, writeFileSync, mkdirSync, chmodSync } from 'node:fs';
import * as cred from '../agent-credentials.mjs';
import * as access from '../agent-access.mjs';
import { plan, run, exitCode } from '../app-cli.mjs';
import { errorResult } from '../tools.mjs';
import { BrainError } from '../brain.mjs';

const tty = { isTTY: true }, pipe = { isTTY: false };

async function home() {
  const root = await mkdtemp(path.join(tmpdir(), 'myman-cred-'));
  return root;
}

test('parseEnvFile accepts export KEY=value and quoted values, ignores unknown keys', () => {
  const values = cred.parseEnvFile(`
# comment
export MYMAN_AGENT_TOKEN=abc123
MYMAN_MACHINE_ID="E69C-ID"
MYMAN_AGENT_ID='grok'
PATH=/evil
export UNKNOWN=nope
`);
  assert.deepEqual(values, {
    MYMAN_AGENT_TOKEN: 'abc123',
    MYMAN_MACHINE_ID: 'E69C-ID',
    MYMAN_AGENT_ID: 'grok',
  });
});

test('loadAgentEnv fills only unset keys from agent.env and never overwrites', async () => {
  const root = await home();
  const dir = path.join(root, '.config', 'myman');
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, 'agent.env');
  await writeFile(file, 'export MYMAN_AGENT_TOKEN=from-file\nexport MYMAN_MACHINE_ID=machine-file\n', { mode: 0o600 });
  const env = { MYMAN_AGENT_TOKEN: 'from-env', HOME: root };
  const result = cred.loadAgentEnv({ env, home: root });
  assert.equal(env.MYMAN_AGENT_TOKEN, 'from-env');
  assert.equal(env.MYMAN_MACHINE_ID, 'machine-file');
  assert.deepEqual(result.loaded_from_file, ['MYMAN_MACHINE_ID']);
  assert.equal(result.ready, true);
  assert.equal(result.keys.MYMAN_AGENT_TOKEN, 'environment');
  assert.equal(result.keys.MYMAN_MACHINE_ID, 'environment_and_file');
  await rm(root, { recursive: true, force: true });
});

test('credentialsStatus never returns secret values and flags loose mode', async () => {
  const root = await home();
  const dir = path.join(root, '.config', 'myman');
  await mkdir(dir, { recursive: true });
  const file = path.join(dir, 'agent.env');
  await writeFile(file, 'MYMAN_AGENT_TOKEN=super-secret-token-value\nMYMAN_MACHINE_ID=mac-1\n', { mode: 0o644 });
  const status = cred.credentialsStatus({ env: {}, home: root });
  assert.equal(status.ready, true);
  assert.equal(status.file_mode_ok, false);
  assert.equal(status.keys.MYMAN_AGENT_TOKEN, 'file');
  const dumped = JSON.stringify(status);
  assert.ok(!dumped.includes('super-secret-token-value'));
  await rm(root, { recursive: true, force: true });
});

test('IDENTITY_REQUIRED and INVALID_CREDENTIAL errors name agent.env and stay distinct from AGENT_DISABLED', () => {
  const env = { PATH: '/usr/bin' };
  const missing = access.annotateError({ code: 'IDENTITY_REQUIRED', message: 'Add an agent in Settings → Agents, then configure MYMAN_AGENT_TOKEN in that host.' }, { env, platform: 'darwin' });
  assert.equal(missing.code, 'IDENTITY_REQUIRED');
  assert.match(missing.hint, /agent\.env|credentials save/);
  assert.match(missing.hint, /not AGENT_DISABLED/);
  assert.equal(missing.agent_may_self_grant, false);
  assert.match(missing.human_command, /agents credentials save/);
  assert.equal(exitCode(missing.code), 6); // not 4
  const bad = access.annotateError({ code: 'INVALID_CREDENTIAL', message: 'Agent credential is invalid or revoked.' }, { env, platform: 'darwin' });
  assert.match(bad.hint, /revoked|invalid/i);
  assert.ok(!/agents grant capture/.test(bad.hint));
  const viaTools = errorResult(new BrainError('IDENTITY_REQUIRED', 'Named agent credentials are now required.'), { platform: 'darwin', env });
  assert.match(viaTools.error.hint, /credentials save/);
});

test('agents credentials save is human-only: refused without TTY or in CI; writes mode 600', async () => {
  const root = await home();
  const env = { MYMAN_AGENT_TOKEN: 'tok', MYMAN_MACHINE_ID: 'mac', CI: 'true', HOME: root };
  await assert.rejects(cred.saveCredentials({ env, home: root, stdin: tty, stdout: tty, stderr: { write() {} }, ask: async () => 'save credentials' }), { code: 'HUMAN_REQUIRED' });
  delete env.CI;
  await assert.rejects(cred.saveCredentials({ env, home: root, stdin: pipe, stdout: tty, stderr: { write() {} }, ask: async () => 'save credentials' }), { code: 'HUMAN_REQUIRED' });
  await assert.rejects(cred.saveCredentials({ env, home: root, stdin: tty, stdout: tty, stderr: { write() {} }, ask: async () => 'yes' }), { code: 'CANCELLED' });
  assert.equal(existsSync(path.join(root, '.config', 'myman', 'agent.env')), false);
  const shown = [];
  const result = await cred.saveCredentials({
    env, home: root, stdin: tty, stdout: tty, stderr: { write: t => shown.push(t) }, ask: async () => 'save credentials',
    writeFileSync, mkdirSync, chmodSync, existsSync, readFileSync,
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.keys_written.sort(), ['MYMAN_AGENT_TOKEN', 'MYMAN_MACHINE_ID']);
  const file = result.path;
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const body = await readFile(file, 'utf8');
  assert.match(body, /export MYMAN_AGENT_TOKEN=/);
  assert.match(body, /does not grant capture\/markup/);
  assert.match(shown.join(''), /type exactly: save credentials/);
  await rm(root, { recursive: true, force: true });
});

test('CLI plans agents credentials status|save and rejects unknown verbs', async () => {
  assert.deepEqual(await plan(['agents', 'credentials', 'status']), { type: 'agents', sub: 'credentials', action: 'status' });
  assert.deepEqual(await plan(['agents', 'credentials', 'save']), { type: 'agents', sub: 'credentials', action: 'save' });
  await assert.rejects(plan(['agents', 'credentials', 'grant']), /INVALID_ARGUMENTS|credentials/);
  await assert.rejects(plan(['agents', 'credentials']), /INVALID_ARGUMENTS|credentials/);
});

test('doctor reports credentials and next_steps for a missing agent.env without confusing it with grants', async () => {
  const root = await home();
  const report = await run(['doctor', '--root', await mkdtemp(path.join(tmpdir(), 'man-doc-'))], {
    platform: 'darwin',
    env: { PATH: '/usr/bin' },
    credentialIo: { home: root },
    accessDeps: {
      platform: () => 'darwin',
      pgrep: async () => false,
      defaults: async () => { throw new Error('missing'); },
    },
    request: async () => { throw new BrainError('APP_NOT_RUNNING', 'Open the updated My Man app, then retry.'); },
  });
  assert.equal(report.credentials.ready, false);
  assert.equal(report.credentials.file_exists, false);
  assert.ok(report.next_steps.some(step => step.id === 'save_credentials'));
  assert.ok(report.next_steps.some(step => step.id === 'grant_capture'));
  assert.ok(report.next_steps.some(step => step.id === 'launch_app'));
  const plain = await run(['doctor', '--plain', '--root', await mkdtemp(path.join(tmpdir(), 'man-doc-'))], {
    platform: 'darwin',
    env: { PATH: '/usr/bin' },
    credentialIo: { home: root },
    accessDeps: {
      platform: () => 'darwin',
      pgrep: async () => false,
      defaults: async () => { throw new Error('missing'); },
    },
    request: async () => { throw new BrainError('APP_NOT_RUNNING', 'Open the updated My Man app, then retry.'); },
  });
  assert.match(plain.plain, /Credentials:/);
  assert.match(plain.plain, /MYMAN_AGENT_TOKEN/);
  assert.ok(!JSON.stringify(report).includes('super-secret'));
  await rm(root, { recursive: true, force: true });
});

test('loading agent.env into process env still leaves agents grant human-only', async () => {
  const root = await home();
  const dir = path.join(root, '.config', 'myman');
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'agent.env'), 'export MYMAN_AGENT_TOKEN=tok\nexport MYMAN_MACHINE_ID=mac\n', { mode: 0o600 });
  const env = { PATH: '/usr/bin', HOME: root };
  cred.loadAgentEnv({ env, home: root });
  assert.equal(env.MYMAN_AGENT_TOKEN, 'tok');
  const deps = {
    platform: () => 'darwin',
    pgrep: async () => false,
    defaults: async () => { throw new Error('should not write'); },
  };
  await assert.rejects(access.change('grant', ['capture'], {
    deps, env, stdin: tty, stdout: tty, stderr: { write() {} }, ask: async () => 'grant capture',
  }), { code: 'HUMAN_REQUIRED' });
  await rm(root, { recursive: true, force: true });
});
