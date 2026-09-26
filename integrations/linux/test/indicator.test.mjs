import assert from 'node:assert/strict';
import test from 'node:test';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

test('captures and recordings notify the person and show in the bar status', async t => {
  const base = await mkdtemp(path.join(tmpdir(), 'myman-indicator-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const log = path.join(base, 'notify.log');
  await writeFile(path.join(base, 'notify-send'), `#!/bin/sh\nprintf '%s|' "$@" >> '${log}'\necho >> '${log}'\n`);
  await chmod(path.join(base, 'notify-send'), 0o755);
  process.env.PATH = `${base}:${process.env.PATH}`;
  process.env.XDG_STATE_HOME = path.join(base, 'state');
  const { announce, indicator } = await import('../indicator.mjs');
  const idle = await indicator();
  assert.equal(idle.text, ''); assert.equal(idle.class, 'idle');
  await announce('screenshot.capture', { id: 'shot-1', window: { app: 'Firefox' } });
  const shot = await indicator();
  assert.equal(shot.class, 'capture'); assert.equal(shot.last_capture_id, 'shot-1');
  await announce('recording.start', { session_id: 'rec-session-x', max_duration: 30 });
  await announce('note.create', {});
  for (let i = 0; i < 40; i++) { if ((await readFile(log, 'utf8').catch(() => '')).split('\n').filter(Boolean).length >= 2) break; await new Promise(r => setTimeout(r, 50)); }
  const lines = (await readFile(log, 'utf8')).trim().split('\n');
  assert.equal(lines.length, 2, 'only capture and recording actions notify');
  assert.match(lines[0], /An agent took a screenshot\|Window: Firefox/);
  assert.match(lines[1], /--urgency=critical.*x-dunst-stack-tag:myman-recording.*An agent is recording your screen/);
});

test('a missing notifier never breaks the action', async () => {
  const { announce } = await import('../indicator.mjs');
  const saved = process.env.PATH; process.env.PATH = '/nonexistent';
  try { await announce('screenshot.capture', { id: 'shot-2' }); } finally { process.env.PATH = saved; }
});
