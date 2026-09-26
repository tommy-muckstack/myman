import { readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { captureRect, screens } from './images.mjs';
import * as cursor from './cursor.mjs';
import { saveRecording } from './library.mjs';
import { processIdentity } from './process-identity.mjs';
import { atomic, dependencies, directory, fail, readSafe, run, statePath, unsupported } from './system.mjs';

// Linux screen recording: X11 via ffmpeg x11grab, Wayland (Hyprland/Sway) via
// wf-recorder. Video only; microphone, system audio, webcam and window capture
// remain Mac-only. Sessions are durable files so any later CLI/MCP process
// (not only the one that started it) can stop, cancel or inspect them.
const sessionId = /^rec-session-[0-9a-f-]{36}$/;
const DEFAULT_MAX = 300;
async function sessionsDir() { return directory(path.join(statePath(), 'recordings'), true, true); }
// `record start --hide-cursor` is a Linux-only CLI flag, so it cannot ride in
// the shared recording.start schema. The CLI leaves a short-lived request
// file that the next start (in the worker) consumes.
const cursorRequest = async () => path.join(await sessionsDir(), 'hide-cursor-request.json');
export async function requestHiddenCursor() { await writeFile(await cursorRequest(), JSON.stringify({ expires: Date.now() + 20_000 }), { mode: 0o600 }); }
async function takeHiddenCursor() {
  const file = await cursorRequest(), taken = `${file}.${process.pid}`;
  try { await rename(file, taken); } catch { return false; }
  try { return JSON.parse(await readFile(taken, 'utf8')).expires > Date.now(); } catch { return false; } finally { await rm(taken, { force: true }); }
}
async function sessionFile(id) {
  if (!sessionId.test(id || '')) fail('INVALID_ARGUMENTS', 'Use the session_id returned by recording.start.');
  return path.join(await sessionsDir(), `${id}.json`);
}
async function load(id) {
  try { return JSON.parse((await readSafe(await sessionFile(id), 64 * 1024, true)).toString()); }
  catch (error) { if (error.code === 'ENOENT') fail('UNKNOWN_SESSION', 'No recording session with that ID.'); throw error; }
}
const save = async session => atomic(await sessionFile(session.session_id), JSON.stringify(session));
async function recorderAlive(session) {
  if (!session.pid || !session.process_identity) return false;
  const current = await processIdentity(session.pid);
  return current !== null && JSON.stringify(current) === JSON.stringify(session.process_identity);
}
// Pausing finalizes the current segment and resuming starts a new one, so
// both backends produce clean files; stop joins them. `recorded` counts
// seconds in finished segments; `run_started_at` is the live segment's start.
const elapsed = session => {
  const until = session.ended_at ? Date.parse(session.ended_at) : Date.now();
  if (session.recorded === undefined) return Math.max(0, (until - Date.parse(session.started_at)) / 1000);
  return session.recorded + (session.state === 'recording' && session.run_started_at ? Math.max(0, (until - Date.parse(session.run_started_at)) / 1000) : 0);
};
function publicSession(session, live) {
  const { pid, process_identity, file, segments, run_started_at, recorded, tracker, ...rest } = session;
  const state = session.state === 'recording' && !live ? 'finished' : session.state;
  return { ...rest, state, elapsed: +elapsed(session).toFixed(2), remaining: ['recording', 'paused'].includes(state) ? +Math.max(0, session.max_duration - elapsed(session)).toFixed(2) : 0 };
}

export async function start(args) {
  if (args.microphone || args.system_audio || args.webcam) unsupported('Linux recording is video-only. Microphone, system audio and webcam capture are Mac-only.');
  if (args.window_id) unsupported('Window recording is not supported on Linux. Use --display or --region.');
  const desktop = await screens(), deps = await dependencies();
  let [x, y, w, h] = captureRect(args, desktop);
  w -= w % 2; h -= h % 2; // H.264 with yuv420p needs even dimensions.
  if (w < 2 || h < 2) fail('INVALID_ARGUMENTS', 'Recording region is too small.');
  const max = args.max_duration ?? DEFAULT_MAX;
  const dir = await sessionsDir();
  // Only one active recording per login: a second concurrent recorder is
  // almost always an agent that lost its session ID.
  for (const name of await readdir(dir)) if (name.endsWith('.json')) {
    const other = JSON.parse((await readSafe(path.join(dir, name), 64 * 1024, true)).toString());
    if (other.state === 'recording' && await recorderAlive(other)) fail('RECORDING_ACTIVE', `Recording ${other.session_id} is still running. Stop or cancel it first.`);
  }
  const hideCursor = await takeHiddenCursor();
  if (hideCursor && desktop.session === 'wayland') unsupported('--hide-cursor needs X11 for now; on Wayland the cursor is always in the video. record polish still adds a highlight and click ripples around it.');
  const id = randomUUID(), session_id = `rec-session-${id}`;
  const session = { session_id, state: 'recording', backend: desktop.session === 'wayland' ? 'wf-recorder' : 'ffmpeg', session_type: desktop.session, origin: desktop.origin ?? [0, 0], started_at: new Date().toISOString(), max_duration: max, region: [x, y, w, h], width: w, height: h, recorded: 0, segments: [], ...(hideCursor ? { cursor_hidden: true } : {}) };
  await launch(session);
  return { ...publicSession(session, true), next: `Stop with: myman record stop --session-id ${session_id} --json` };
}
async function launch(session) {
  const deps = await dependencies(), [x, y, w, h] = session.region, seconds = Math.max(1, Math.ceil(session.max_duration - session.recorded));
  const file = path.join(await sessionsDir(), `${session.session_id.slice(12)}-${session.segments.length}.mp4`);
  let file_, argv;
  if (session.session_type === 'wayland') {
    if (!deps['wf-recorder']) fail('DEPENDENCY_MISSING', 'Install wf-recorder for Wayland (Hyprland/Sway) recording.');
    [file_, argv] = [deps['wf-recorder'], ['-y', '-g', `${x + session.origin[0]},${y + session.origin[1]} ${w}x${h}`, '-c', 'libx264', '-p', 'preset=veryfast', '-x', 'yuv420p', '-f', file]];
  } else {
    if (!deps.ffmpeg) fail('DEPENDENCY_MISSING', 'Install ffmpeg for X11 screen recording.');
    // captureRect returns X11 top-left coordinates for the capture backends.
    [file_, argv] = [deps.ffmpeg, ['-nostdin', '-loglevel', 'error', '-f', 'x11grab', '-draw_mouse', session.cursor_hidden ? '0' : '1', '-framerate', '30', '-video_size', `${w}x${h}`, '-i', `${process.env.DISPLAY}+${x},${y}`, '-t', String(seconds), '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-y', file]];
  }
  const child = spawn(file_, argv, { detached: true, stdio: 'ignore', env: process.env });
  const spawned = await new Promise(resolve => { child.once('spawn', () => resolve(true)); child.once('error', () => resolve(false)); });
  if (!spawned) fail('BACKEND_FAILED', `${path.basename(file_)} could not start.`);
  child.unref();
  Object.assign(session, { state: 'recording', file, pid: child.pid, process_identity: await processIdentity(child.pid), run_started_at: new Date().toISOString() });
  await save(session);
  // Fail fast when the recorder exits immediately (bad DISPLAY, no permission).
  await new Promise(r => setTimeout(r, 600));
  if (!await recorderAlive(session)) {
    await rm(file, { force: true });
    if (!session.segments.length) { session.state = 'failed'; session.ended_at = new Date().toISOString(); await save(session); fail('BACKEND_FAILED', 'The recorder exited immediately. Check doctor and desktop access.'); }
    Object.assign(session, { state: 'paused', file: null, run_started_at: null }); await save(session);
    fail('BACKEND_FAILED', 'The recorder could not restart; the recording is still paused and earlier footage is kept.');
  }
  await startTracker(session);
}
// Cursor tracking runs beside the recorder (MYMAN_CURSOR_TRACK=0 turns it off).
const cursorLog = async session => path.join(await sessionsDir(), `${session.session_id.slice(12)}.cursor.jsonl`);
async function startTracker(session) {
  if (process.env.MYMAN_CURSOR_TRACK === '0') return;
  const child = spawn(process.execPath, [path.join(path.dirname(fileURLToPath(import.meta.url)), 'cli.mjs'), 'record', 'track', session.session_id], { detached: true, stdio: 'ignore', env: { ...process.env, MYMAN_AGENT_TOKEN: '' } });
  const spawned = await new Promise(resolve => { child.once('spawn', () => resolve(true)); child.once('error', () => resolve(false)); });
  if (!spawned) return;
  child.unref();
  session.tracker = { pid: child.pid, process_identity: await processIdentity(child.pid) };
  await save(session);
}
async function stopTracker(session) {
  const t = session.tracker;
  if (!t) return;
  const up = async () => { const now = await processIdentity(t.pid); return now !== null && JSON.stringify(now) === JSON.stringify(t.process_identity); };
  if (await up()) { try { process.kill(t.pid, 'SIGTERM'); } catch {} for (let i = 0; i < 30 && await up(); i++) await new Promise(r => setTimeout(r, 100)); if (await up()) try { process.kill(t.pid, 'SIGKILL'); } catch {} }
  session.tracker = null;
}
// The detached tracker (spawned above) for the live segment of one session.
export async function trackSession(session_id) {
  const session = await load(session_id);
  if (session.state !== 'recording') return { ok: true, tracking: false };
  await cursor.track(session, await cursorLog(session), async () => { try { const now = await load(session_id); return now.state === 'recording' && now.run_started_at === session.run_started_at && await recorderAlive(now); } catch { return false; } });
  return { ok: true };
}
export async function cursorTrack(session, duration) { return cursor.build(await cursorLog(session), { width: session.width, height: session.height, duration, cursorInVideo: !session.cursor_hidden }); }
// Finish the live segment and fold its duration into `recorded`.
async function closeSegment(session) {
  if (!session.file) return;
  await stopTracker(session);
  await halt(session);
  const info = await stat(session.file).catch(() => null);
  if (info && info.size >= 1024) {
    session.segments.push(session.file);
    const now = Date.now(), wall = (now - Date.parse(session.run_started_at)) / 1000;
    session.recorded = Math.min(session.max_duration, session.recorded + Math.max(0, Math.min(wall, (await probe(session.file)) ?? wall)));
  } else await rm(session.file, { force: true });
  Object.assign(session, { file: null, pid: null, process_identity: null, run_started_at: null });
}
async function halt(session) {
  if (!await recorderAlive(session)) return;
  process.kill(session.pid, 'SIGINT'); // ffmpeg and wf-recorder finalize the MP4 on SIGINT.
  for (let i = 0; i < 150 && await recorderAlive(session); i++) await new Promise(r => setTimeout(r, 100));
  if (await recorderAlive(session)) { process.kill(session.pid, 'SIGKILL'); fail('PROCESSING_TIMEOUT', 'The recorder did not finalize within 15 seconds and was stopped; the video may be unusable.'); }
}
async function probe(file) {
  const deps = await dependencies();
  if (!deps.ffprobe) return null;
  try { const { stdout } = await run(deps.ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]); const d = parseFloat(stdout); return Number.isFinite(d) ? d : null; } catch { return null; }
}
export async function pause({ session_id }) {
  const session = await load(session_id);
  if (session.state !== 'recording' || !session.segments) fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}${session.segments ? '' : ' and was started before pause support'}.`);
  if (!await recorderAlive(session)) fail('SESSION_NOT_ACTIVE', 'The recording already reached its time limit. Stop it to save.');
  await closeSegment(session);
  Object.assign(session, { state: 'paused', paused_at: new Date().toISOString() }); await save(session);
  return { ...publicSession(session, false), next: `Resume with: myman record resume --session-id ${session_id} --json` };
}
export async function resume({ session_id }) {
  const session = await load(session_id);
  if (session.state !== 'paused') fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}.`);
  if (session.recorded >= session.max_duration - 0.5) fail('SESSION_NOT_ACTIVE', 'The recording has no time left. Stop it to save.');
  const dir = await sessionsDir();
  for (const name of await readdir(dir)) if (name.endsWith('.json') && name !== `${session_id}.json`) {
    const other = JSON.parse((await readSafe(path.join(dir, name), 64 * 1024, true)).toString());
    if (other.state === 'recording' && await recorderAlive(other)) fail('RECORDING_ACTIVE', `Recording ${other.session_id} is running. Stop or cancel it first.`);
  }
  delete session.paused_at;
  await launch(session);
  return { ...publicSession(session, true), next: `Pause or stop with: myman record pause|stop --session-id ${session_id} --json` };
}
async function join(session) {
  if (session.segments.length === 1) return session.segments[0];
  const deps = await dependencies(), list = path.join(await sessionsDir(), `${session.session_id.slice(12)}-list.txt`), out = path.join(await sessionsDir(), `${session.session_id.slice(12)}-joined.mp4`);
  await atomic(list, session.segments.map(f => `file '${f.replaceAll("'", "'\\''")}'`).join('\n') + '\n');
  try { await run(deps.ffmpeg, ['-nostdin', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-movflags', '+faststart', '-y', out]); }
  finally { await rm(list, { force: true }); }
  return out;
}
export async function stop({ session_id }) {
  const session = await load(session_id);
  if (session.state === 'saved') return session.result;
  if (!['recording', 'paused'].includes(session.state)) fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}.`);
  const legacy = !session.segments;
  if (legacy) { await halt(session); session.segments = []; const info = await stat(session.file).catch(() => null); if (info && info.size >= 1024) session.segments.push(session.file); session.file = null; }
  else await closeSegment(session);
  session.ended_at = new Date().toISOString();
  if (!session.segments.length) { session.state = 'failed'; await save(session); fail('BACKEND_FAILED', 'The recorder produced no usable video.'); }
  if (session.segments.length > 1 && !(await dependencies()).ffmpeg) fail('DEPENDENCY_MISSING', 'Install ffmpeg to join paused recording segments.');
  const file = await join(session);
  const duration = await probe(file) ?? elapsed(session);
  const track = process.env.MYMAN_CURSOR_TRACK === '0' ? null : await cursorTrack(session, duration);
  const result = await saveRecording({ file, width: session.width, height: session.height, duration, started_at: session.started_at, backend: session.backend, cursor: track });
  for (const f of new Set([file, ...session.segments])) await rm(f, { force: true });
  await cursor.cleanup(await cursorLog(session));
  Object.assign(session, { state: 'saved', result, segments: [] }); await save(session);
  return result;
}
export async function cancel({ session_id }) {
  const session = await load(session_id);
  if (!['recording', 'paused'].includes(session.state)) fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}.`);
  await stopTracker(session);
  if (await recorderAlive(session)) process.kill(session.pid, 'SIGKILL');
  for (const f of [session.file, ...(session.segments ?? [])]) if (f) await rm(f, { force: true });
  await cursor.cleanup(await cursorLog(session));
  session.segments = [];
  Object.assign(session, { state: 'canceled', ended_at: new Date().toISOString() }); await save(session);
  return publicSession(session, false);
}
export async function status({ session_id } = {}) {
  if (session_id) { const s = await load(session_id); return publicSession(s, await recorderAlive(s)); }
  const dir = await sessionsDir(), all = [];
  for (const name of await readdir(dir)) if (name.endsWith('.json')) { const s = JSON.parse((await readSafe(path.join(dir, name), 64 * 1024, true)).toString()); all.push(publicSession(s, await recorderAlive(s))); }
  all.sort((a, b) => b.started_at.localeCompare(a.started_at));
  return { active: all.find(s => s.state === 'recording' || s.state === 'paused') ?? null, sessions: all.slice(0, 20) };
}
