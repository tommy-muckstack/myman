import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { lstat, mkdir, rename, stat, writeFile } from 'node:fs/promises';
import { compose, wav, VERSION as MUSIC_VERSION, TRACKS } from '../linux/music.mjs';
import { randomUUID } from 'node:crypto';
import catalog from './actions.json' with { type: 'json' };
import { BrainError } from './brain.mjs';
export { catalog };

export async function request(payload, { socketPath = process.env.MYMAN_AGENT_SOCKET ?? `/tmp/myman-${process.getuid()}/control.sock`, timeout = 15000 } = {}) {
  payload = { ...(process.env.MYMAN_AGENT_TOKEN ? {credential:process.env.MYMAN_AGENT_TOKEN} : {}), ...(process.env.MYMAN_MACHINE_ID ? {machine_id:process.env.MYMAN_MACHINE_ID} : {}), ...payload };
  let folder, socket;
  try { [folder, socket] = await Promise.all([lstat(path.dirname(socketPath)), lstat(socketPath)]); }
  catch { throw new BrainError('APP_NOT_RUNNING', 'Open the updated My Man app, then retry. This command requires its local action bridge.'); }
  if (!folder.isDirectory() || folder.isSymbolicLink() || folder.uid !== process.getuid() || (folder.mode & 0o777) !== 0o700 || !socket.isSocket() || socket.uid !== process.getuid() || (socket.mode & 0o777) !== 0o600) throw new BrainError('INVALID_SOCKET', 'My Man command socket ownership or permissions are invalid.');
  const line = JSON.stringify(payload) + '\n';
  if (Buffer.byteLength(line) > 1024 * 1024) throw new BrainError('TOO_LARGE', 'Action arguments exceed 1 MiB.');
  return await new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath); let data = Buffer.alloc(0), settled = false;
    const finish = (error, result) => { if (settled) return; settled = true; clearTimeout(timer); client.destroy(); error ? reject(error) : resolve(result); };
    const timer = setTimeout(() => finish(new BrainError('CONNECTION_TIMEOUT', `No reply. Inspect job ${payload.id ?? ''} before repeating a mutation.`)), timeout);
    client.on('connect', () => client.write(line));
    client.on('error', () => finish(new BrainError('APP_UNAVAILABLE', `Local connection failed. Inspect job ${payload.id ?? ''} before repeating a mutation.`)));
    client.on('end', () => { if (!settled) finish(new BrainError('INCOMPLETE_REPLY', `App disconnected. Inspect job ${payload.id ?? ''} before repeating a mutation.`)); });
    client.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      if (data.length > 16 * 1024 * 1024) return finish(new BrainError('TOO_LARGE', 'App reply exceeded 16 MiB.'));
      const newline = data.indexOf(10); if (newline < 0) return;
      try { const reply = JSON.parse(data.subarray(0, newline)); if (!reply || typeof reply.ok !== 'boolean') throw new Error(); if (!reply.ok) return finish(new BrainError(reply.error?.code ?? 'ACTION_FAILED', reply.error?.message ?? 'Action failed.')); finish(null, reply); }
      catch { finish(new BrainError('INVALID_REPLY', 'App returned invalid JSON.')); }
    });
  });
}
export function describe(action) {
  if (!action) return catalog;
  const found = catalog.actions.find(a => a.name === action);
  if (!found) throw new BrainError('UNKNOWN_ACTION', 'Use actions to discover supported actions.');
  return found;
}
export async function discover(action, { transport = request, offline = false } = {}) {
  let value, live = false, unavailable;
  if (!offline) {
    try { value = (await transport({method:'actions'})).result; live = true; }
    catch (error) {
      if (!['APP_NOT_RUNNING','APP_UNAVAILABLE','CONNECTION_TIMEOUT','INCOMPLETE_REPLY'].includes(error.code)) throw error;
      unavailable = {code:error.code,message:error.message};
    }
  }
  value ??= catalog;
  if (!Array.isArray(value.actions)) throw new BrainError('INVALID_REPLY','App returned an invalid action catalog.');
  const metadata = {source:live?'running_app':'bundled_cli',live,verified_available:live,app_version:value.app_version??null,...(unavailable?{unavailable}:{})};
  if (!action) return {...value,...metadata};
  const found = value.actions.find(a=>a.name===action);
  if (!found) throw new BrainError('UNSUPPORTED_ACTION',`The ${live?'running app':'bundled CLI'} does not advertise ${action}. Update MyMan and check actions again.`);
  return {...found,...metadata};
}
// The app can mix any audio file, but the built-in tracks are composed in
// code here (the same music as Linux), cached, and handed over as a file.
export function musicTrack(args) {
  const flag = args.music, recipe = args.recipe?.music;
  if (typeof flag === 'string') return flag.startsWith('/') || flag === 'none' ? null : flag;
  if (flag !== undefined) return null;
  if (typeof recipe === 'string') return recipe.startsWith('/') || recipe === 'none' ? null : recipe;
  if (recipe === true) return 'upbeat';
  if (recipe && typeof recipe === 'object' && !recipe.file) return recipe.track ?? 'upbeat';
  return null;
}
export async function musicFile(track, { cache = path.join(os.homedir(), 'Library', 'Caches', 'MyMan', 'music') } = {}) {
  const file = path.join(cache, `${track}-v${MUSIC_VERSION}.wav`);
  try { if ((await stat(file)).size > 44) return file; } catch {}
  await mkdir(cache, { recursive: true, mode: 0o700 });
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temp, wav(compose(track)), { mode: 0o600 });
  await rename(temp, file);
  return file;
}
// A demo polishes with the upbeat track unless its script says otherwise.
export async function withDemoMusic(args, options) {
  const script = args.script;
  if (!script || typeof script !== 'object' || Array.isArray(script) || script.polish === false || args.dry_run === true) return args;
  const polish = script.polish && typeof script.polish === 'object' && !Array.isArray(script.polish) ? script.polish : {};
  if (script.polish !== undefined && polish !== script.polish) return args; // the app reports the bad recipe
  const music = polish.music === undefined ? 'upbeat' : polish.music;
  const next = await withMusic({ recipe: { music } }, options);
  if (!next.music_track) return args;
  return { ...args, music_track: next.music_track, script: { ...script, polish: { ...polish, music: next.recipe.music } } };
}
export async function withMusic(args, options) {
  const raw = musicTrack(args); if (raw === null) return args;
  const track = String(raw).toLowerCase();
  if (!Object.hasOwn(TRACKS, track)) throw new BrainError('INVALID_ARGUMENTS', `Music must be one of ${Object.keys(TRACKS).join(', ')}, an absolute path to an audio file, or none.`);
  const file = await musicFile(track, options), next = { ...args, music_track: track };
  if (typeof args.music === 'string') next.music = file;
  else { const m = typeof args.recipe.music === 'object' && args.recipe.music ? { ...args.recipe.music } : {}; delete m.track; next.recipe = { ...args.recipe, music: { ...m, file } }; }
  return next;
}
export async function invoke(action, args = {}, { id = randomUUID(), wait = true, transport = request, waitMs = 300000 } = {}) {
  const live = await discover(action,{transport});
  if (!live.live) throw new BrainError(live.unavailable?.code??'APP_NOT_RUNNING',live.unavailable?.message??'Open MyMan to verify this action.');
  if (action === 'recording.polish') args = await withMusic(args);
  if (action === 'demo.run') args = await withDemoMusic(args);
  const first = await transport({ method: 'invoke', id, action, arguments: args });
  if (!wait) return first;
  const deadline = Date.now() + waitMs;
  let reply = first;
  while (reply.job?.state === 'running' && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 200));
    reply = await transport({ method: 'job', id });
    if (reply.launch_id !== first.launch_id && !reply.recovered) throw new BrainError('APP_RESTARTED', `App restarted; inspect job ${id}. Do not replay automatically.`);
  }
  return reply;
}
