import { mkdir, rm, rmdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { atomic, command, directory, fail, readSafe, run, statePath } from './system.mjs';
import { notify } from './indicator.mjs';

// Timers and reminders, matching AgentQuickTools.swift on the Mac. State is a
// private file; each pending deadline is armed as a transient systemd user
// timer when a user manager is running, otherwise as a detached waiter
// process. Every fire re-checks state and a generation number, so a paused,
// canceled or rescheduled item never fires from a stale schedule.
const owner = () => (process.env.MYMAN_AGENT_ID || 'agent').slice(0, 120);
const file = async () => path.join(await directory(statePath(), true, true), 'quick-tools.json');
async function load() {
  try { return JSON.parse((await readSafe(await file(), 1024 * 1024, true)).toString()); }
  catch (error) { if (error.code === 'ENOENT') return { timers: [], reminders: [] }; throw error; }
}
async function locked(fn) {
  const lock = (await file()) + '.lock';
  for (let i = 0; ; i++) {
    try { await mkdir(lock, { mode: 0o700 }); break; }
    catch (error) { if (error.code !== 'EEXIST' || i > 100) fail('BUSY', 'Timer state is locked; try again.'); await new Promise(r => setTimeout(r, 50)); }
  }
  try { const state = await load(); const result = await fn(state); await atomic(await file(), JSON.stringify(state)); return result; }
  finally { await rmdir(lock).catch(() => {}); }
}

let managerCache;
async function systemdUser() {
  if (managerCache !== undefined) return managerCache;
  const systemctl = await command('systemctl'), systemdRun = await command('systemd-run');
  if (!systemctl || !systemdRun || process.env.MYMAN_TIMER_BACKEND === 'process') return managerCache = null;
  try { const { stdout } = await run(systemctl, ['--user', 'is-system-running'], { timeout: 3000 }); managerCache = /running|degraded/.test(stdout) ? systemdRun : null; }
  catch (error) { managerCache = /running|degraded/.test(error.stdout ?? '') ? systemdRun : null; }
  return managerCache;
}
const unit = (kind, id, gen) => `myman-${kind}-${id}-${gen}`;
async function arm(kind, item) {
  const seconds = Math.max(1, Math.ceil((Date.parse(item.deadline) - Date.now()) / 1000));
  const worker = fileURLToPath(new URL('./worker.mjs', import.meta.url)), argv = [process.execPath, worker, '--fire', kind, item.id, String(item.generation)];
  const systemdRun = await systemdUser();
  if (systemdRun) {
    try {
      await run(systemdRun, ['--user', '--quiet', '--collect', `--unit=${unit(kind, item.id, item.generation)}`, `--on-active=${seconds}s`, '--timer-property=AccuracySec=1s',
        ...['DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'XDG_STATE_HOME', 'MYMAN_BRAIN_ROOT', 'MYMAN_CONFIG'].filter(k => process.env[k]).map(k => `--setenv=${k}=${process.env[k]}`), ...argv], { timeout: 10_000 });
      return 'systemd';
    } catch {}
  }
  const child = spawn(argv[0], [...argv.slice(1), '--wait', String(seconds)], { detached: true, stdio: 'ignore', env: process.env });
  child.unref();
  return 'process';
}
async function disarm(kind, item) {
  if (item.scheduler !== 'systemd') return; // Process waiters exit on their own after the generation check.
  const systemctl = await command('systemctl');
  if (systemctl) await run(systemctl, ['--user', 'stop', `${unit(kind, item.id, item.generation)}.timer`], { timeout: 5000 }).catch(() => {});
}
function sound() {
  for (const [cmd, args] of [['canberra-gtk-play', ['-i', 'complete']], ['paplay', ['/usr/share/sounds/freedesktop/stereo/complete.oga']]]) {
    try { const c = spawn(cmd, args, { detached: true, stdio: 'ignore' }); c.on('error', () => {}); c.unref(); return; } catch {}
  }
}

const remaining = t => Math.max(0, t.state === 'paused' ? t.remaining_at_pause : t.state === 'running' ? (Date.parse(t.deadline) - Date.now()) / 1000 : 0);
function timerJSON(t) {
  return { active: true, session_id: t.id, state: t.state, sound_enabled: t.sound_enabled, duration_seconds: t.duration, remaining_seconds: +remaining(t).toFixed(1), ...(t.state === 'running' ? { deadline: t.deadline } : {}), scheduler: t.scheduler };
}
function timerStatus(state, id) {
  const active = state.timers.filter(t => ['running', 'paused'].includes(t.state));
  const base = { requires_app_open: false, active_count: active.length };
  const current = active.find(t => t.id === id);
  return current ? { ...base, ...timerJSON(current) } : { ...base, active: false, state: 'idle', remaining_seconds: 0 };
}
function reminderJSON(r) {
  return { id: r.id, message: r.message, at: r.at, due: r.fired || Date.parse(r.at) <= Date.now(), notification_scheduled: !!r.scheduler, requires_app_open: !r.scheduler, sound_enabled: r.sound_enabled, scheduler: r.scheduler, ...(r.scheduler === 'process' ? { survives_logout: false } : {}) };
}
// Fire anything overdue that a lost waiter (logout, reboot) never delivered.
async function catchUp(state) {
  for (const t of state.timers) if (t.state === 'running' && Date.parse(t.deadline) <= Date.now() - 5000) { t.state = 'finished'; deliver('timer', t); }
  for (const r of state.reminders) if (!r.fired && !r.dismissed && Date.parse(r.at) <= Date.now() - 5000) { r.fired = true; deliver('reminder', r); }
  state.timers = state.timers.filter(t => ['running', 'paused'].includes(t.state) || Date.now() - Date.parse(t.updated_at) < 86400_000);
}
function deliver(kind, item) {
  if (kind === 'timer') notify('Timer finished', `${Math.round(item.duration)} second timer is done.`, { urgency: 'normal', icon: 'alarm-symbolic', timeout: 0, tag: `myman-timer-${item.id}` });
  else notify('Reminder', item.message.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])), { urgency: 'normal', icon: 'alarm-symbolic', timeout: 0, tag: `myman-reminder-${item.id}` });
  if (item.sound_enabled) sound();
}

export function parseAt(value) {
  // ISO 8601 with an explicit offset or Z, as the Mac requires.
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$/.test(value)) fail('INVALID_ARGUMENTS', 'at must be an ISO 8601 timestamp with a time-zone offset.');
  const t = Date.parse(value); if (!Number.isFinite(t)) fail('INVALID_ARGUMENTS', 'at must be an ISO 8601 timestamp with a time-zone offset.');
  return new Date(t);
}
const mine = (item, what) => { if (item.owner !== owner()) fail('NOT_OWNER', `Only the ${what}'s creating agent or human controls can change it.`); };

export async function timerStart({ seconds, sound_enabled = true }) {
  if (!Number.isFinite(seconds) || seconds < 1 || seconds > 86400) fail('INVALID_ARGUMENTS', 'seconds must be 1 to 86400.');
  return locked(async state => {
    await catchUp(state);
    const t = { id: `timer-${randomUUID()}`, owner: owner(), state: 'running', duration: seconds, sound_enabled, generation: 1, deadline: new Date(Date.now() + seconds * 1000).toISOString(), updated_at: new Date().toISOString() };
    t.scheduler = await arm('timer', t); state.timers.push(t);
    return timerStatus(state, t.id);
  });
}
export async function timerStatusAction() {
  return locked(async state => {
    await catchUp(state);
    const active = state.timers.filter(t => ['running', 'paused'].includes(t.state));
    const newest = active.at(-1);
    return { ...timerStatus(state, newest?.id), timers: active.map(timerJSON) };
  });
}
export async function timerChange(action, { session_id, enabled }) {
  return locked(async state => {
    await catchUp(state);
    const t = state.timers.find(x => x.id === session_id && ['running', 'paused'].includes(x.state));
    if (!t) fail('SESSION_MISMATCH', 'This timer is no longer active. Inspect timer.status.');
    mine(t, 'timer');
    if (action === 'timer.cancel') { await disarm('timer', t); t.state = 'canceled'; }
    else if (action === 'timer.sound') t.sound_enabled = enabled;
    else if (action === 'timer.pause' && t.state === 'running') { await disarm('timer', t); t.remaining_at_pause = remaining(t); t.state = 'paused'; t.generation++; }
    else if (action === 'timer.resume' && t.state === 'paused') { t.deadline = new Date(Date.now() + t.remaining_at_pause * 1000).toISOString(); t.state = 'running'; t.generation++; t.scheduler = await arm('timer', t); }
    t.updated_at = new Date().toISOString();
    return action === 'timer.cancel' ? { ...timerStatus(state, null), session_id: t.id, state: 'canceled' } : timerStatus(state, t.id);
  });
}
export async function reminderCreate({ message, seconds, at, sound_enabled = true }) {
  if ((seconds !== undefined) === (at !== undefined)) fail('INVALID_ARGUMENTS', 'Provide seconds or at, not both.');
  if (typeof message !== 'string' || !message.trim()) fail('INVALID_ARGUMENTS', 'message is required.');
  const date = seconds !== undefined ? new Date(Date.now() + seconds * 1000) : parseAt(at);
  return locked(async state => {
    await catchUp(state);
    const r = { id: randomUUID(), owner: owner(), message: message.slice(0, 500), at: date.toISOString(), deadline: date.toISOString(), sound_enabled, generation: 1, fired: false, dismissed: false, created_at: new Date().toISOString() };
    if (date.getTime() <= Date.now()) { r.fired = true; r.scheduler = 'immediate'; deliver('reminder', r); } else r.scheduler = await arm('reminder', r);
    state.reminders.push(r);
    return reminderJSON(r);
  });
}
export async function reminderList() {
  return locked(async state => { await catchUp(state); return { reminders: state.reminders.filter(r => !r.dismissed).map(reminderJSON) }; });
}
export async function reminderChange(action, { id, enabled }) {
  return locked(async state => {
    const r = state.reminders.find(x => x.id === id && !x.dismissed);
    if (!r) fail('NOT_FOUND', 'Reminder not found.');
    mine(r, 'reminder');
    if (action === 'reminder.sound') { r.sound_enabled = enabled; return reminderJSON(r); }
    await disarm('reminder', r); r.dismissed = true; r.generation++;
    return { dismissed: r.id };
  });
}
// Entry point for a scheduled fire (systemd unit or detached waiter).
export async function fire(kind, id, generation, waitSeconds) {
  if (waitSeconds) await new Promise(r => setTimeout(r, Number(waitSeconds) * 1000));
  await locked(async state => {
    const list = kind === 'timer' ? state.timers : state.reminders, item = list.find(x => x.id === id);
    if (!item || item.generation !== Number(generation)) return;
    if (kind === 'timer' && item.state !== 'running') return;
    if (kind === 'reminder' && (item.fired || item.dismissed)) return;
    if (Date.parse(item.deadline) > Date.now() + 1500) { await arm(kind, item); return; } // clock moved; re-arm
    if (kind === 'timer') { item.state = 'finished'; item.updated_at = new Date().toISOString(); } else item.fired = true;
    deliver(kind, item);
  });
}
