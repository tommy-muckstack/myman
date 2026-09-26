import assert from 'node:assert/strict';
import test from 'node:test';
import os from 'node:os';
import path from 'node:path';
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises';

const dir = await mkdtemp(path.join(os.tmpdir(), 'myman-timers-'));
const bin = path.join(dir, 'bin'), log = path.join(dir, 'notify.log');
await (await import('node:fs/promises')).mkdir(bin);
await writeFile(path.join(bin, 'notify-send'), `#!/bin/sh\nprintf '%s|' "$@" >> '${log}'; echo >> '${log}'\n`); await chmod(path.join(bin, 'notify-send'), 0o755);
Object.assign(process.env, { XDG_STATE_HOME: path.join(dir, 'state'), MYMAN_TIMER_BACKEND: 'process', PATH: `${bin}:${process.env.PATH}` });
delete process.env.MYMAN_AGENT_ID;
const t = await import('../timers.mjs');
const wait = ms => new Promise(r => setTimeout(r, ms));
const notices = async () => (await readFile(log, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean);

test('timers run, pause without firing, resume, and stay owned by their agent', async () => {
  const quick = await t.timerStart({ seconds: 1 });
  assert.equal(quick.state, 'running'); assert.equal(quick.requires_app_open, false);
  const long = await t.timerStart({ seconds: 3, sound_enabled: false });
  const paused = await t.timerChange('timer.pause', { session_id: long.session_id });
  assert.equal(paused.state, 'paused'); assert.ok(paused.remaining_seconds > 2);
  process.env.MYMAN_AGENT_ID = 'someone-else';
  await assert.rejects(t.timerChange('timer.cancel', { session_id: long.session_id }), e => e.code === 'NOT_OWNER');
  delete process.env.MYMAN_AGENT_ID;
  await wait(4000);
  const status = await t.timerStatusAction();
  assert.deepEqual(status.timers.map(x => x.state), ['paused'], 'the paused timer did not fire from its old schedule');
  assert.equal((await notices()).filter(n => n.includes('Timer finished')).length, 1);
  await t.timerChange('timer.cancel', { session_id: long.session_id });
  await assert.rejects(t.timerChange('timer.resume', { session_id: long.session_id }), e => e.code === 'SESSION_MISMATCH');
  await assert.rejects(t.timerStart({ seconds: 0 }), e => e.code === 'INVALID_ARGUMENTS');
});

test('reminders need seconds or an ISO time with offset, notify once, and escape markup', async () => {
  await assert.rejects(t.reminderCreate({ message: 'x' }), e => e.code === 'INVALID_ARGUMENTS');
  await assert.rejects(t.reminderCreate({ message: 'x', seconds: 5, at: '2030-01-01T09:00:00Z' }), e => e.code === 'INVALID_ARGUMENTS');
  await assert.rejects(t.reminderCreate({ message: 'x', at: '2030-01-01 09:00' }), /time-zone offset/);
  const later = await t.reminderCreate({ message: 'Later', at: '2030-01-01T09:00:00-05:00' });
  assert.equal(later.at, '2030-01-01T14:00:00.000Z'); assert.equal(later.due, false); assert.equal(later.notification_scheduled, true);
  const soon = await t.reminderCreate({ message: 'Stretch <b>now</b>', seconds: 1 });
  await wait(2500);
  const listed = (await t.reminderList()).reminders;
  assert.equal(listed.find(r => r.id === soon.id).due, true);
  const fired = (await notices()).filter(n => n.includes('Reminder|'));
  assert.equal(fired.length, 1); assert.ok(fired[0].includes('Stretch &lt;b&gt;now&lt;/b&gt;'));
  assert.deepEqual(await t.reminderChange('reminder.cancel', { id: later.id }), { dismissed: later.id });
  assert.ok(!(await t.reminderList()).reminders.some(r => r.id === later.id));
  await assert.rejects(t.reminderChange('reminder.cancel', { id: later.id }), e => e.code === 'NOT_FOUND');
});
