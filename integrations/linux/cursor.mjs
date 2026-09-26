import { appendFile, readFile, rm } from 'node:fs/promises';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { command, fail } from './system.mjs';

// Cursor tracking for screen recordings. While a recording runs, a companion
// process logs where the pointer is (about 20 times a second, only when it
// moves), each click, and the moments someone types. Key presses are logged
// as "a key was pressed" only, never which key. Times are seconds into the
// finished video (pauses excluded); positions are pixels inside the recorded
// region. Auto-zoom, cursor effects and demos are built on this log.
const exec = promisify(execFile);
export const RATE = 20;
async function pointer(sessionType) {
  if (sessionType === 'wayland') {
    if (process.env.HYPRLAND_INSTANCE_SIGNATURE && await command('hyprctl')) return async () => { const { stdout } = await exec('hyprctl', ['cursorpos', '-j'], { timeout: 1000 }); const p = JSON.parse(stdout); return [p.x, p.y]; };
    return null; // Sway and other compositors do not expose the pointer position.
  }
  if (!(await command('xdotool'))) return null;
  return async () => { const { stdout } = await exec('xdotool', ['getmouselocation', '--shell'], { timeout: 1000 }); return [Number(/X=(-?\d+)/.exec(stdout)[1]), Number(/Y=(-?\d+)/.exec(stdout)[1])]; };
}
// X11 clicks and typing moments through XInput2 raw events (xorg-xinput).
async function inputEvents(sessionType, onEvent) {
  if (sessionType === 'wayland' || !(await command('xinput'))) return null;
  const child = spawn('xinput', ['test-xi2', '--root'], { stdio: ['ignore', 'pipe', 'ignore'] });
  let buffer = '', pending = null;
  child.stdout.on('data', chunk => {
    buffer += chunk; const lines = buffer.split('\n'); buffer = lines.pop();
    for (const line of lines) {
      const type = /EVENT type \d+ \((Raw(?:ButtonPress|KeyPress))\)/.exec(line);
      if (type) { pending = type[1]; if (pending === 'RawKeyPress') { onEvent({ e: 'key' }); pending = null; } continue; }
      const detail = /^\s+detail: (\d+)/.exec(line);
      if (detail && pending === 'RawButtonPress') { const b = Number(detail[1]); if (b >= 1 && b <= 3) onEvent({ e: 'click', b }); pending = null; }
    }
  });
  return child;
}
// Runs detached next to the recorder; `session` is a snapshot at segment start.
export async function track(session, logFile, alive, { exit = true } = {}) {
  const read = await pointer(session.session_type);
  const [rx, ry, w, h] = session.region, ox = rx + (session.session_type === 'wayland' ? session.origin[0] : 0), oy = ry + (session.session_type === 'wayland' ? session.origin[1] : 0);
  const base = session.recorded || 0, began = Date.parse(session.run_started_at) || Date.now();
  const t = () => +(base + (Date.now() - began) / 1000).toFixed(2);
  let last = null, lines = [], stopped = false;
  const inside = ([x, y]) => [Math.round(x - ox), Math.round(y - oy)];
  const flush = async () => { if (lines.length) { const out = lines.join(''); lines = []; await appendFile(logFile, out, { mode: 0o600 }); } };
  const events = await inputEvents(session.session_type, ev => { const at = last || [null, null]; lines.push(JSON.stringify({ t: t(), ...(ev.e === 'click' ? { x: at[0], y: at[1] } : {}), ...ev }) + '\n'); });
  lines.push(JSON.stringify({ t: t(), e: 'info', pointer: read ? 'tracked' : 'unavailable', input: events ? 'tracked' : 'unavailable' }) + '\n');
  const finish = async () => { if (stopped) return; stopped = true; events?.kill(); await flush(); if (exit) process.exit(0); };
  if (exit) { process.on('SIGTERM', finish); process.on('SIGINT', finish); }
  let tick = 0;
  while (!stopped) {
    if (read) { try { const p = inside(await read()); if (!last || p[0] !== last[0] || p[1] !== last[1]) { last = p; lines.push(JSON.stringify({ t: t(), x: p[0], y: p[1] }) + '\n'); } } catch {} }
    if (++tick % RATE === 0) { await flush(); if (!(await alive()) || t() > session.max_duration + 1) break; }
    await new Promise(r => setTimeout(r, 1000 / RATE));
  }
  await finish();
}
// Fold the raw log into the saved track: compact arrays plus a summary that
// says, in plain terms, where the action is.
export async function build(logFile, { width, height, duration, cursorInVideo = true }) {
  let raw = '';
  try { raw = await readFile(logFile, 'utf8'); } catch {}
  const moves = [], clicks = [], keys = []; let pointerOk = true, inputOk = raw.length > 0, scripted = false;
  for (const line of raw.split('\n')) {
    if (!line) continue; let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.t > duration + 0.5) continue;
    if (r.e === 'info') { pointerOk = r.pointer !== 'unavailable' && pointerOk; inputOk = r.input === 'tracked' && inputOk; }
    else if (r.e === 'click') { clicks.push([r.t, r.x, r.y, r.b]); if (r.by === 'demo') scripted = true; }
    else if (r.e === 'key') { keys.push(r.t); if (r.by === 'demo') scripted = true; }
    else moves.push([r.t, r.x, r.y]);
  }
  moves.sort((a, b) => a[0] - b[0]); clicks.sort((a, b) => a[0] - b[0]); keys.sort((a, b) => a - b);
  return { version: 1, rate: RATE, width, height, duration, cursor_in_video: cursorInVideo, pointer: pointerOk && moves.length ? 'tracked' : 'unavailable', clicks_tracked: inputOk || scripted, ...(scripted ? { input_from: 'demo script' } : {}), fields: { moves: ['t', 'x', 'y'], clicks: ['t', 'x', 'y', 'button'], keys: ['t'] }, moves, clicks, keys, activity: activity({ moves, clicks, keys, width, height, duration }) };
}
// Where something is happening: clicks and typing bursts, plus places the
// pointer settled after moving. Each span has a focus point and a reason.
export function activity({ moves, clicks, keys, width, height, duration }) {
  const events = [];
  for (const [t, x, y] of clicks) if (x !== null) events.push({ t, x, y, reason: 'click' });
  const at = t => { let p = null; for (const m of moves) { if (m[0] > t) break; p = m; } return p; };
  for (let i = 0; i < keys.length;) { let j = i; while (j + 1 < keys.length && keys[j + 1] - keys[j] < 1.5) j++; if (j - i >= 2) { const p = at(keys[i]); events.push({ t: keys[i], end: keys[j], x: p?.[1] ?? width / 2, y: p?.[2] ?? height / 2, reason: 'typing' }); } i = j + 1; }
  for (let i = 1; i < moves.length; i++) {
    const gap = (moves[i + 1]?.[0] ?? duration) - moves[i][0], travel = Math.hypot(moves[i][1] - moves[i - 1][1], moves[i][2] - moves[i - 1][2]);
    if (gap >= 1.2 && travel > 4) events.push({ t: moves[i][0], x: moves[i][1], y: moves[i][2], reason: 'pointer settled' });
  }
  events.sort((a, b) => a.t - b.t);
  const spans = [];
  for (const e of events) {
    if (e.x < 0 || e.y < 0 || e.x > width || e.y > height) continue;
    const start = Math.max(0, e.t - 0.6), end = Math.min(duration, (e.end ?? e.t) + 2), last = spans.at(-1);
    if (last && start <= last.end + 1.5 && Math.hypot(e.x - last.x, e.y - last.y) < Math.min(width, height) / 4) { last.end = Math.max(last.end, end); last.reasons.add(e.reason); }
    else spans.push({ start, end, x: e.x, y: e.y, reasons: new Set([e.reason]) });
  }
  return spans.map(s => ({ start: +s.start.toFixed(2), end: +s.end.toFixed(2), x: Math.round(s.x), y: Math.round(s.y), reasons: [...s.reasons] }));
}
export function summary(track) {
  const words = track.pointer === 'tracked' ? `${track.moves.length} pointer positions` : 'pointer position unavailable';
  return `${words}, ${track.clicks.length} clicks, ${track.keys.length} key presses${track.clicks_tracked ? '' : ' (clicks and typing are not detected on this desktop)'}, ${track.activity.length} moments of activity`;
}
export async function cleanup(logFile) { await rm(logFile, { force: true }); }
// myman record cursor --id REC-ID: the saved track for one recording.
export async function read(id, { full = false } = {}) {
  const { rootPath, readSafe } = await import('./system.mjs');
  if (!/^rec-[0-9a-f-]{36}$/.test(id || '')) fail('INVALID_ARGUMENTS', 'Use a recording id such as rec-… from record stop or library search --kind recordings.');
  const root = rootPath(), catalog = JSON.parse((await readSafe(`${root}/catalog.json`, 64 * 1024 * 1024)).toString());
  const entry = catalog.exports.find(e => e.item_id === id);
  if (!entry) fail('NOT_FOUND', 'No recording with that id.');
  if (!entry.cursor_path || !entry.cursor_path.startsWith(`${root}/assets/recording-cursor/`)) fail('NOT_FOUND', 'This recording has no cursor track (it was made before cursor tracking, or tracking was off).');
  const track = JSON.parse((await readSafe(entry.cursor_path, 32 * 1024 * 1024)).toString());
  const { moves, ...rest } = track;
  return { ok: true, id, path: entry.cursor_path, summary: summary(track), ...rest, ...(full ? { moves } : { moves_count: moves.length, note: 'Add --full for every pointer position.' }) };
}
