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

test('custom music accepts plain audio formats only, never playlists or scripts', async () => {
  const { musicFormatAllowed } = await import('../studio.mjs');
  for (const ok of ['mp3', 'wav', 'flac', 'ogg', 'mov,mp4,m4a,3gp,3g2,mj2', 'matroska,webm', 'aac']) assert.equal(musicFormatAllowed(ok), true, ok);
  for (const bad of ['hls', 'concat', 'ffconcat', 'image2', 'lavfi', 'mp3,hls', '', undefined]) assert.equal(musicFormatAllowed(bad), false, String(bad));
});

test('recording cursor tracks are kept out of the Brain Git history', async t => {
  const { command } = await import('../system.mjs');
  if (!await command('git') || !await command('ffmpeg')) return t.skip('git and ffmpeg are required');
  const { writeFile, readFile } = await import('node:fs/promises');
  const home = await mkdtemp(path.join(await realpath(tmpdir()), 'myman-cursor-git-'));
  const brain = path.join(home, 'brain'), video = path.join(home, 'v.mp4');
  spawnSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=64x48:r=10:d=1', '-pix_fmt', 'yuv420p', '-y', video]);
  const env = { ...process.env, MYMAN_BRAIN_ROOT: brain, XDG_STATE_HOME: path.join(home, 'state'), XDG_CONFIG_HOME: path.join(home, 'config') };
  const cursor = { version: 1, pointer: 'tracked', clicks_tracked: true, moves: [[0, 1, 1]], clicks: [], keys: [0.5, 0.7], activity: [] };
  const lib = new URL('../library.mjs', import.meta.url).href;
  const script = `const {saveRecording}=await import(${JSON.stringify(lib)});process.stdout.write(JSON.stringify(await saveRecording(${JSON.stringify({ file: video, width: 64, height: 48, duration: 1, started_at: new Date().toISOString(), backend: 'test', cursor })})));`;
  const out = spawnSync(process.execPath, ['--input-type=module', '-e', script], { env });
  const saved = JSON.parse(out.stdout.toString());
  await readFile(saved.cursor.path);
  const tracked = spawnSync('git', ['-C', brain, 'ls-files'], { env }).stdout.toString();
  assert.doesNotMatch(tracked, /recording-cursor/, 'the cursor track is not committed');
  assert.match(await readFile(path.join(brain, '.gitignore'), 'utf8'), /^assets\/recording-cursor\/$/m);
});
