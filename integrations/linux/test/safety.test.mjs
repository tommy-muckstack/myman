import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { itemFile } from '../items.mjs';

test('library delete only accepts a Markdown file inside a library folder', () => {
  for (const ok of ['notes/2026-09-26-abcd.md', 'screenshots/x.md', 'task-items/0f.md', 'dictations/d.md']) assert.equal(itemFile(ok), true, ok);
  for (const bad of ['notes', 'notes/', '.', '', '../notes/x.md', 'notes/../catalog.json', '/tmp/x.md', 'notes/sub/x.md', 'assets/x.md', 'notes/.hidden.md', 'notes/x.png', undefined, null]) assert.equal(itemFile(bad), false, String(bad));
});

test('dictation save passes text through and saves nothing until the person connects it', async () => {
  const home = await mkdtemp(path.join(await realpath(tmpdir()), 'myman-dict-optin-'));
  const env = { ...process.env, XDG_CONFIG_HOME: path.join(home, 'config'), MYMAN_BRAIN_ROOT: path.join(home, 'brain'), XDG_RUNTIME_DIR: home };
  delete env.MYMAN_AGENT_TOKEN;
  const cli = new URL('../cli.mjs', import.meta.url).pathname;
  const out = spawnSync(process.execPath, [cli, 'dictation', 'save'], { input: 'not connected yet', env });
  assert.equal(out.stdout.toString(), 'not connected yet'); assert.equal(out.status, 0);
  await new Promise(r => setTimeout(r, 1500));
  assert.deepEqual(await readdir(path.join(home, 'brain/dictations')).catch(() => []), []);
  assert.deepEqual((await readdir(home)).filter(f => f.startsWith('myman-dictation-')), [], 'no temp copy left behind');
});
