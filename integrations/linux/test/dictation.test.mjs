import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const here = path.dirname(new URL(import.meta.url).pathname), cli = path.join(here, '../cli.mjs');
const voxtype = 'state_file = "auto"\n\n[whisper]\nmodel = "base.en"\n\n[output]\nmode = "type"\n';
const chained = '[output.post_process]\ncommand = "tr a-z A-Z"\ntimeout_ms = 2000\n';
const settle = async (dir, count) => { for (let i = 0; i < 50; i++) { const files = await readdir(dir).catch(() => []); if (files.length >= count) return files; await new Promise(r => setTimeout(r, 100)); } return readdir(dir).catch(() => []); };

test('dictation connect hooks Voxtype, keeps a cleanup step, saves to the Brain, and disconnect restores', async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'myman-dictation-'));
  const env = { ...process.env, XDG_CONFIG_HOME: path.join(home, 'config'), MYMAN_BRAIN_ROOT: path.join(home, 'brain'), XDG_RUNTIME_DIR: home };
  delete env.MYMAN_AGENT_TOKEN;
  Object.assign(process.env, { XDG_CONFIG_HOME: env.XDG_CONFIG_HOME, MYMAN_BRAIN_ROOT: env.MYMAN_BRAIN_ROOT });
  const config = path.join(home, 'config/voxtype/config.toml');
  await mkdir(path.dirname(config), { recursive: true });
  const d = await import('../dictation.mjs');
  await assert.rejects(d.connect({ skipCheck: true }), { code: 'NOT_FOUND' });
  await writeFile(config, voxtype + '\n' + chained);
  const first = await d.connect({ skipCheck: true });
  assert.equal(first.connected, true); assert.equal(first.chained_command, 'tr a-z A-Z');
  assert.equal((await d.connect({ skipCheck: true })).already, true);
  const text = await readFile(config, 'utf8');
  assert.equal(text.match(/\[output\.post_process\]/g).length, 1, 'one post_process table');
  assert.match(text, /command = ".* dictation save"/);
  // Voxtype runs the command with the text on stdin; it must come straight back.
  const out = spawnSync(process.execPath, [cli, 'dictation', 'save'], { input: 'hello from voxtype', env });
  assert.equal(out.stdout.toString(), 'HELLO FROM VOXTYPE'); assert.equal(out.status, 0);
  const files = await settle(path.join(home, 'brain/dictations'), 1);
  assert.equal(files.length, 1);
  const doc = await readFile(path.join(home, 'brain/dictations', files[0]), 'utf8');
  assert.match(doc, /^---\nid: [0-9a-f-]{36}\ncreated: .+\nsource: "voxtype"\ncaptured_local: .+\ntz: ".+"\ntimezone_source: capture\n/);
  assert.match(doc, /\n# HELLO FROM VOXTYPE\n\nHELLO FROM VOXTYPE\n$/);
  const catalog = JSON.parse(await readFile(path.join(home, 'brain/catalog.json'), 'utf8'));
  assert.equal(catalog.exports.find(e => e.kind === 'dictations').item_id.startsWith('dictation-'), true);
  // An agent credential never adds dictations, but the text still passes through.
  const agent = spawnSync(process.execPath, [cli, 'dictation', 'save'], { input: 'agent text', env: { ...env, MYMAN_AGENT_TOKEN: 'x' } });
  assert.equal(agent.stdout.toString(), 'AGENT TEXT');
  await new Promise(r => setTimeout(r, 1000));
  assert.equal((await readdir(path.join(home, 'brain/dictations'))).length, 1);
  await d.disconnect({ skipCheck: true });
  const restored = await readFile(config, 'utf8');
  assert.ok(!restored.includes('myman')); assert.ok(restored.includes(chained.trim()));
  assert.equal(restored.match(/\[output\.post_process\]/g).length, 1);
});

test('only a person can connect dictation; agents get a clear pointer for the rest', () => {
  const run = args => JSON.parse(spawnSync(process.execPath, [cli, ...args, '--json'], { stdio: ['ignore', 'pipe', 'pipe'] }).stdout.toString());
  assert.equal(run(['dictation', 'connect']).error.code, 'HUMAN_REQUIRED');
  assert.match(run(['dictation', 'start']).error.message, /Voxtype/);
});
