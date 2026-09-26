import { readdir, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { captureRect, screens } from './images.mjs';
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
const elapsed = session => Math.max(0, ((session.ended_at ? Date.parse(session.ended_at) : Date.now()) - Date.parse(session.started_at)) / 1000);
function publicSession(session, live) {
  const { pid, process_identity, file, ...rest } = session;
  const state = session.state === 'recording' && !live ? 'finished' : session.state;
  return { ...rest, state, elapsed: +elapsed(session).toFixed(2), remaining: state === 'recording' ? +Math.max(0, session.max_duration - elapsed(session)).toFixed(2) : 0 };
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
  const id = randomUUID(), session_id = `rec-session-${id}`, file = path.join(dir, `${id}.mp4`);
  let file_, argv;
  if (desktop.session === 'wayland') {
    if (!deps['wf-recorder']) fail('DEPENDENCY_MISSING', 'Install wf-recorder for Wayland (Hyprland/Sway) recording.');
    [file_, argv] = [deps['wf-recorder'], ['-y', '-g', `${x + (desktop.origin?.[0] ?? 0)},${y + (desktop.origin?.[1] ?? 0)} ${w}x${h}`, '-c', 'libx264', '-p', 'preset=veryfast', '-x', 'yuv420p', '-f', file]];
  } else {
    if (!deps.ffmpeg) fail('DEPENDENCY_MISSING', 'Install ffmpeg for X11 screen recording.');
    // captureRect returns X11 top-left coordinates for the capture backends.
    [file_, argv] = [deps.ffmpeg, ['-nostdin', '-loglevel', 'error', '-f', 'x11grab', '-draw_mouse', '1', '-framerate', '30', '-video_size', `${w}x${h}`, '-i', `${process.env.DISPLAY}+${x},${y}`, '-t', String(max), '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-y', file]];
  }
  const child = spawn(file_, argv, { detached: true, stdio: 'ignore', env: process.env });
  const spawned = await new Promise(resolve => { child.once('spawn', () => resolve(true)); child.once('error', () => resolve(false)); });
  if (!spawned) fail('BACKEND_FAILED', `${path.basename(file_)} could not start.`);
  child.unref();
  const session = { session_id, state: 'recording', backend: path.basename(file_), started_at: new Date().toISOString(), max_duration: max, region: [x, y, w, h], width: w, height: h, pid: child.pid, process_identity: await processIdentity(child.pid), file };
  await save(session);
  // Fail fast when the recorder exits immediately (bad DISPLAY, no permission).
  await new Promise(r => setTimeout(r, 600));
  if (!await recorderAlive(session)) {
    session.state = 'failed'; session.ended_at = new Date().toISOString(); await save(session);
    await rm(file, { force: true });
    fail('BACKEND_FAILED', 'The recorder exited immediately. Check doctor and desktop access.');
  }
  return { ...publicSession(session, true), next: `Stop with: myman record stop --session-id ${session_id} --json` };
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
export async function stop({ session_id }) {
  const session = await load(session_id);
  if (session.state === 'saved') return session.result;
  if (session.state !== 'recording') fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}.`);
  await halt(session);
  session.ended_at = new Date().toISOString();
  const info = await stat(session.file).catch(() => null);
  if (!info || info.size < 1024) { session.state = 'failed'; await save(session); fail('BACKEND_FAILED', 'The recorder produced no usable video.'); }
  const duration = await probe(session.file) ?? elapsed(session);
  const result = await saveRecording({ file: session.file, width: session.width, height: session.height, duration, started_at: session.started_at, backend: session.backend });
  await rm(session.file, { force: true });
  Object.assign(session, { state: 'saved', result }); await save(session);
  return result;
}
export async function cancel({ session_id }) {
  const session = await load(session_id);
  if (session.state !== 'recording') fail('SESSION_NOT_ACTIVE', `Recording session is ${session.state}.`);
  if (await recorderAlive(session)) process.kill(session.pid, 'SIGKILL');
  await rm(session.file, { force: true });
  Object.assign(session, { state: 'canceled', ended_at: new Date().toISOString() }); await save(session);
  return publicSession(session, false);
}
export async function status({ session_id } = {}) {
  if (session_id) { const s = await load(session_id); return publicSession(s, await recorderAlive(s)); }
  const dir = await sessionsDir(), all = [];
  for (const name of await readdir(dir)) if (name.endsWith('.json')) { const s = JSON.parse((await readSafe(path.join(dir, name), 64 * 1024, true)).toString()); all.push(publicSession(s, await recorderAlive(s))); }
  all.sort((a, b) => b.started_at.localeCompare(a.started_at));
  return { active: all.find(s => s.state === 'recording') ?? null, sessions: all.slice(0, 20) };
}
