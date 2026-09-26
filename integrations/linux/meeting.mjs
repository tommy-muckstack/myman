import { readdir, rm, stat, rename } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import * as identity from './identity.mjs';
import { notify } from './indicator.mjs';
import { finishMeeting, saveMeeting } from './library.mjs';
import { processIdentity } from './process-identity.mjs';
import { atomic, authorize, command, directory, fail, readSafe, run, statePath } from './system.mjs';

// Linux meetings: record the microphone (and, by default, what the computer
// plays) as two local tracks with ffmpeg, then transcribe them on this
// computer with Whisper. The microphone track is labeled You and the system
// track Others, in the Mac Brain format. Nothing is uploaded and MyMan never
// downloads a model. A notification and the indicator show while recording.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_MINUTES = 240;
const root = () => directory(path.join(statePath(), 'meetings'), true, true);
const sessionFile = async id => path.join(await root(), id, 'session.json');
async function load(id) {
  if (!uuid.test(id || '')) fail('INVALID_ARGUMENTS', 'Use the meeting id returned by myman meeting start.');
  try { return JSON.parse((await readSafe(await sessionFile(id), 64 * 1024, true)).toString()); }
  catch (error) { if (error.code === 'ENOENT') fail('UNKNOWN_SESSION', 'No meeting with that id.'); throw error; }
}
const save = async s => atomic(await sessionFile(s.id), JSON.stringify(s));
async function sessions() {
  const out = [];
  for (const name of await readdir(await root()).catch(() => [])) if (uuid.test(name)) { try { out.push(await load(name)); } catch {} }
  return out.sort((a, b) => b.started_at.localeCompare(a.started_at));
}
async function alive(track) {
  if (!track?.pid || !track.process_identity) return false;
  const now = await processIdentity(track.pid);
  return now !== null && JSON.stringify(now) === JSON.stringify(track.process_identity);
}
const person = () => !process.env.MYMAN_AGENT_TOKEN && process.stdin.isTTY && process.stdout.isTTY;
// The person at the terminal may always record their own meeting. Agents need
// both the recording and the microphone grant (the microphone grant is off by
// default) and a credential that includes both.
async function access() {
  if (person()) return 'person';
  const needs = ['recording', 'microphone'];
  await authorize(needs);
  identity.validate(await identity.authenticate(), needs);
  return 'agent';
}
const seconds = s => Math.max(0, ((s.ended_at ? Date.parse(s.ended_at) : Date.now()) - Date.parse(s.started_at)) / 1000);
const view = s => ({ id: s.id, title: s.title, state: s.state, started_at: s.started_at, ended_at: s.ended_at ?? null, elapsed: Math.round(seconds(s)), tracks: s.tracks.map(t => t.speaker), started_by: s.started_by, ...(s.result ? { meeting: s.result } : {}), ...(s.audio_kept ? { audio: s.tracks.map(t => t.file) } : {}) });
const input = () => ({ format: process.env.MYMAN_AUDIO_FORMAT || 'pulse', mic: process.env.MYMAN_MIC_DEVICE || 'default', system: process.env.MYMAN_SYSTEM_DEVICE || '@DEFAULT_MONITOR@' });
const wait = ms => new Promise(r => setTimeout(r, ms));

export async function status() {
  await access();
  const all = await sessions();
  for (const s of all) if (s.state === 'recording' && !(await Promise.all(s.tracks.map(alive))).some(Boolean)) { s.state = 'interrupted'; s.ended_at ??= new Date().toISOString(); await save(s); }
  const active = all.find(s => s.state === 'recording');
  return { ok: true, active: active ? view(active) : null, recent: all.filter(s => s !== active).slice(0, 5).map(view) };
}

export async function start({ title, systemAudio = true, keepAudio = false, maxMinutes = MAX_MINUTES } = {}) {
  const who = await access();
  if ((await status()).active) fail('MEETING_ACTIVE', 'A meeting is already recording. Stop it first with myman meeting stop.');
  if (!(await command('ffmpeg'))) fail('DEPENDENCY_MISSING', 'Meetings need ffmpeg (Arch/Omarchy: sudo pacman -S ffmpeg).');
  const minutes = Number(maxMinutes);
  if (!Number.isFinite(minutes) || minutes <= 0 || minutes > MAX_MINUTES) fail('INVALID_ARGUMENTS', `--max-minutes must be between 1 and ${MAX_MINUTES}.`);
  const id = randomUUID(), dir = await directory(path.join(await root(), id), true, true), src = input();
  const wanted = [{ speaker: 'You', device: src.mic, file: path.join(dir, 'you.wav') }, ...(systemAudio ? [{ speaker: 'Others', device: src.system, file: path.join(dir, 'others.wav') }] : [])];
  const tracks = [];
  for (const t of wanted) {
    const child = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-f', src.format, '-i', t.device, '-t', String(Math.round(minutes * 60)), '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', t.file], { detached: true, stdio: 'ignore' });
    child.unref();
    tracks.push({ ...t, pid: child.pid, process_identity: await processIdentity(child.pid) });
  }
  await wait(900);
  const up = await Promise.all(tracks.map(alive));
  if (!up[0]) {
    for (const t of tracks) try { process.kill(t.pid, 'SIGKILL'); } catch {}
    await rm(dir, { recursive: true, force: true });
    fail('DEVICE_UNAVAILABLE', `Could not open the microphone (${src.format} ${src.mic}). On Omarchy, check that PipeWire is running and a microphone is connected (wpctl status).`);
  }
  const live = tracks.filter((t, i) => up[i]);
  const s = { id, title: String(title || 'Meeting').slice(0, 200), state: 'recording', started_at: new Date().toISOString(), max_minutes: minutes, keep_audio: !!keepAudio, started_by: who === 'person' ? 'person' : identity.principal()?.name || 'agent', tracks: live };
  await save(s);
  notify('MyMan is recording a meeting', `${s.title}. Microphone${live.length > 1 ? ' and computer audio' : ''} are recording on this computer. Stop: myman meeting stop`, { urgency: 'normal', icon: 'audio-input-microphone', timeout: 8000, tag: 'myman-meeting' });
  return { ok: true, ...view(s), ...(systemAudio && live.length < 2 ? { warning: 'Computer audio could not be recorded, so only your microphone is recording. Other people will not be in the transcript.' } : {}) };
}

async function halt(s) {
  for (const t of s.tracks) if (await alive(t)) try { process.kill(t.pid, 'SIGINT'); } catch {}
  for (let i = 0; i < 50 && (await Promise.all(s.tracks.map(alive))).some(Boolean); i++) await wait(200);
  for (const t of s.tracks) if (await alive(t)) try { process.kill(t.pid, 'SIGKILL'); } catch {}
}
async function pick(id) {
  if (id) return load(id);
  if (!person()) fail('INVALID_ARGUMENTS', 'Pass --id with the meeting id returned by myman meeting start.');
  // The live meeting, or one whose recorder already ended (time limit or a
  // device that went away) but was never stopped and saved.
  const { active, recent } = await status();
  const target = active || recent.find(s => s.state === 'interrupted' && !s.meeting);
  if (!target) fail('UNKNOWN_SESSION', 'No meeting is recording.');
  return load(target.id);
}

export async function stop({ id, keepAudio } = {}) {
  await access();
  const s = await pick(id);
  if (s.result) return { ok: true, ...view(s) };
  if (!['recording', 'interrupted'].includes(s.state)) fail('INVALID_STATE', `This meeting is ${s.state}.`);
  await halt(s);
  s.ended_at ??= new Date().toISOString();
  if (keepAudio !== undefined) s.keep_audio = !!keepAudio;
  s.result = await saveMeeting({ id: s.id, title: s.title, started_at: s.started_at, ended_at: s.ended_at, status: 'processing', message: '_Transcribing on this computer. This note updates when it finishes._' });
  s.state = 'transcribing';
  await save(s);
  const worker = spawn(process.execPath, [path.join(path.dirname(fileURLToPath(import.meta.url)), 'cli.mjs'), 'meeting', 'transcribe', s.id], { detached: true, stdio: 'ignore', env: { ...process.env, MYMAN_AGENT_TOKEN: '' } });
  worker.unref();
  notify('MyMan stopped the meeting recording', `${s.title} is saved. The transcript is being written on this computer.`, { urgency: 'low', icon: 'audio-input-microphone', tag: 'myman-meeting' });
  return { ok: true, ...view(s), next: `Read it when ready: myman library search --kind meetings --json (transcript_status turns ready).` };
}

export async function cancel({ id } = {}) {
  await access();
  const s = await pick(id);
  if (s.result) fail('INVALID_STATE', 'This meeting was already saved; delete it from the library instead.');
  await halt(s);
  await rm(path.dirname(await sessionFile(s.id)), { recursive: true, force: true });
  notify('MyMan canceled the meeting recording', 'Nothing was saved.', { urgency: 'low', icon: 'audio-input-microphone', tag: 'myman-meeting' });
  return { ok: true, id: s.id, state: 'canceled', saved: false };
}

// ---- local transcription ----
async function model() {
  if (process.env.MYMAN_WHISPER_MODEL) return process.env.MYMAN_WHISPER_MODEL;
  const data = process.env.XDG_DATA_HOME || path.join(homedir(), '.local/share');
  for (const dir of [path.join(data, 'voxtype/models'), path.join(data, 'whisper.cpp/models'), path.join(data, 'whisper/models')]) {
    const found = (await readdir(dir).catch(() => [])).filter(f => /^ggml-.*\.bin$/.test(f)).sort();
    if (found.length) return path.join(dir, found.find(f => /base|small/.test(f)) || found[0]);
  }
  return null;
}
export async function engine() {
  if (process.env.MYMAN_TRANSCRIBE_COMMAND) return { name: 'custom', run: file => run('sh', ['-c', `${process.env.MYMAN_TRANSCRIBE_COMMAND} "$1"`, 'sh', file], { timeout: 600000 }).then(r => r.stdout) };
  const cli = (await command('whisper-cli')) ? 'whisper-cli' : (await command('whisper-cpp')) ? 'whisper-cpp' : null, m = await model();
  if (cli && m) return { name: `${cli} (${path.basename(m)})`, run: file => run(cli, ['-m', m, '-f', file, '-nt', '-np'], { timeout: 600000 }).then(r => r.stdout) };
  if (await command('voxtype')) return { name: 'voxtype', run: file => run('voxtype', ['transcribe', file], { timeout: 600000 }).then(r => /No speech detected/i.test(r.stdout) ? '' : r.stdout.replace(/\r/g, '').split(/\n\s*\n/).pop()) };
  return null;
}
async function duration(file) {
  const r = await run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]).catch(() => ({ stdout: '0' }));
  return Number(r.stdout.trim()) || 0;
}
// Speech spans between silences, merged into chunks of up to 30 seconds.
async function spans(file) {
  const total = await duration(file);
  if (total < 0.3) return [];
  const r = await run('ffmpeg', ['-hide_banner', '-nostats', '-nostdin', '-i', file, '-af', 'silencedetect=noise=-35dB:d=0.7', '-f', 'null', '-'], { timeout: 600000 }).catch(e => ({ stderr: e.stderr || '' }));
  const log = String(r.stderr || ''), silences = [];
  for (const m of log.matchAll(/silence_start: ([\d.]+)[\s\S]*?(?:silence_end: ([\d.]+)|$)/g)) silences.push([Number(m[1]), m[2] ? Number(m[2]) : total]);
  const speech = []; let at = 0;
  for (const [a, b] of silences) { if (a - at > 0.3) speech.push([at, a]); at = b; }
  if (total - at > 0.3) speech.push([at, total]);
  const chunks = [];
  for (const [a, b] of speech) {
    for (let x = a; x < b; x += 30) {
      const y = Math.min(b, x + 30), last = chunks.at(-1);
      if (last && x - last[1] < 1.5 && y - last[0] <= 30) last[1] = y; else chunks.push([x, y]);
    }
  }
  return chunks;
}
const stamp = t => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
const clean = text => String(text || '').replace(/\[(?:BLANK_AUDIO|MUSIC|NOISE)\]|\((?:silence|music)\)/gi, ' ').replace(/\s+/g, ' ').trim();

export async function transcribe(id) {
  const s = await load(id);
  if (!s.result || s.state !== 'transcribing') return { ok: true, ...view(s) };
  let status = 'ready', transcript, speakers = [];
  try {
    const eng = await engine();
    if (!eng) { status = 'unavailable'; transcript = '_No local transcription engine was found, so the audio was kept on this computer. Install voxtype (Omarchy dictation) or whisper.cpp with a ggml model, then run `myman meeting transcribe ' + s.id + '`._'; s.keep_audio = true; }
    else {
      const lines = [];
      for (const t of s.tracks) {
        if (!(await stat(t.file).catch(() => null))) continue;
        for (const [a, b] of await spans(t.file)) {
          const part = path.join(path.dirname(t.file), `chunk-${t.speaker}-${Math.round(a * 1000)}.wav`);
          await run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-ss', String(a), '-t', String(b - a), '-i', t.file, '-c:a', 'pcm_s16le', part]);
          const text = clean(await eng.run(part));
          await rm(part, { force: true });
          if (text) lines.push({ at: a, speaker: t.speaker, text });
        }
      }
      lines.sort((x, y) => x.at - y.at || (x.speaker === 'You' ? -1 : 1));
      speakers = [...new Set(lines.map(l => l.speaker))];
      transcript = lines.length ? lines.map(l => `**${l.speaker}** [${stamp(l.at)}]: ${l.text}`).join('\n\n') : '_No speech was detected in this recording._';
      s.engine = eng.name;
    }
  } catch (error) { status = 'failed'; transcript = `_Transcription failed on this computer (${clean(error.message).slice(0, 200)}). The audio was kept; retry with \`myman meeting transcribe ${s.id}\`._`; s.keep_audio = true; }
  s.git = await finishMeeting({ brain_path: s.result.brain_path, status, transcript, speakers });
  s.result = { ...s.result, transcript_status: status };
  s.state = status === 'ready' ? 'done' : status;
  s.audio_kept = !!s.keep_audio;
  if (!s.keep_audio) for (const t of s.tracks) await rm(t.file, { force: true });
  await save(s);
  notify(status === 'ready' ? 'Meeting transcript is ready' : 'Meeting transcript needs attention', `${s.title}: ${status === 'ready' ? 'saved to your Brain' : status}.`, { urgency: status === 'ready' ? 'low' : 'normal', icon: 'audio-input-microphone', tag: 'myman-meeting' });
  return { ok: true, ...view(s) };
}
// Retrying a failed or unavailable transcript is the same worker, rearmed.
export async function retry(id) {
  await access();
  const s = await load(id);
  if (!['failed', 'unavailable'].includes(s.state)) return transcribe(id);
  s.state = 'transcribing'; await save(s);
  return transcribe(id);
}
// The stop worker (and a person retrying) both land here: a meeting still
// marked transcribing is finished; anything else is a retry and needs access.
export async function resume(id) {
  const s = await load(id);
  return s.state === 'transcribing' && !process.env.MYMAN_AGENT_TOKEN ? transcribe(id) : retry(id);
}
// For the Waybar indicator: is a meeting recording right now? No grants
// needed, because it only tells the person what is already happening.
export async function activeMeeting() {
  for (const s of await sessions()) if (s.state === 'recording' && (await Promise.all(s.tracks.map(alive))).some(Boolean)) return { id: s.id, title: s.title, elapsed: seconds(s), remaining: Math.max(0, s.max_minutes * 60 - seconds(s)) };
  return null;
}
