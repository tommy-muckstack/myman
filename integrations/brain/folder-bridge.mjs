// Folder transport for app actions: the same requests the local socket takes,
// written as files under <Brain>/agent and answered there by the running app.
// It exists for agents that cannot reach the socket at all, such as a cloud
// agent whose only access to the Mac is a connected folder. The app decides
// everything: this file grants nothing and cannot turn the bridge on.
import { lstat, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { BrainError } from './brain.mjs';

export const HEARTBEAT_ALIVE_SECONDS = 30;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SWITCH = 'Accept commands through the Brain folder';
const fail = (code, message, hint) => { const error = new BrainError(code, message); if (hint) error.hint = hint; throw error; };

export function bridgeDirectory({ root, env = process.env } = {}) {
  if (env.MYMAN_BRIDGE_DIR) return env.MYMAN_BRIDGE_DIR;
  return path.join(root ?? env.MYMAN_BRAIN_ROOT ?? path.join(homedir(), 'MyManBrain'), 'agent');
}
export function bridgeRequested(flag, env = process.env) { return !!flag || ['1', 'true', 'on'].includes(String(env.MYMAN_BRIDGE ?? '').toLowerCase()); }

async function json(file) { try { return JSON.parse(await readFile(file, 'utf8')); } catch { return undefined; } }
async function exists(file) { try { await lstat(file); return true; } catch { return false; } }
// audit.log has one JSON line per event; only the tail is read so it stays cheap.
async function auditKnows(directory, id) {
  let text;
  try { text = await readFile(path.join(directory, 'audit.log'), 'utf8'); } catch { return false; }
  return text.slice(-2 * 1024 * 1024).split('\n').some(line => line.includes(id) && line.includes('"id"') && (() => { try { return JSON.parse(line).id === id; } catch { return false; } })());
}
async function isDirectory(file) { try { const info = await lstat(file); return info.isDirectory() && !info.isSymbolicLink(); } catch { return false; } }

// What doctor reports: is the folder there, can this process write a request,
// has the app turned the bridge on, and is its watcher still beating.
export async function bridgeStatus(directory, { now = Date.now() } = {}) {
  const inbox = path.join(directory, 'inbox');
  const exists = await isDirectory(directory) && await isDirectory(inbox);
  let writable = false;
  if (exists) {
    const probe = path.join(inbox, `.doctor-${randomUUID()}.tmp`);
    try { await writeFile(probe, '', { flag: 'wx', mode: 0o600 }); writable = true; } catch {}
    try { await unlink(probe); } catch {}
  }
  const manifest = await json(path.join(directory, 'manifest.json'));
  const beat = await json(path.join(directory, 'heartbeat.json'));
  const age = typeof beat?.epoch === 'number' ? Math.round(now / 1000 - beat.epoch) : null;
  const alive = age !== null && Math.abs(age) <= HEARTBEAT_ALIVE_SECONDS;
  const enabled = manifest?.enabled === true;
  const problems = [];
  if (!exists) problems.push({ code: 'BRIDGE_NOT_FOUND', message: `No bridge folder at ${directory}.`, hint: `A person turns on "${SWITCH}" in My Man Settings → Agents, and the Brain folder must be connected to this agent.` });
  else {
    if (!writable) problems.push({ code: 'BRIDGE_NOT_WRITABLE', message: `Cannot write to ${inbox}.`, hint: 'Connect the Brain folder with write access.' });
    if (!enabled) problems.push({ code: 'BRIDGE_DISABLED', message: 'The folder bridge is turned off in My Man.', hint: `A person turns on "${SWITCH}" in My Man Settings → Agents.` });
    else if (!alive) problems.push({ code: 'APP_NOT_RUNNING', message: age === null ? 'My Man has not written a heartbeat.' : `The last heartbeat is ${age} seconds old.`, hint: 'Ask the person to open My Man on the Mac. If it is open, compare this computer\'s clock with heartbeat.json.' });
  }
  return { ok: problems.length === 0, directory, exists, writable, enabled, app_version: manifest?.app_version ?? null,
    heartbeat: { present: !!beat, at: beat?.at ?? null, age_seconds: age, alive }, ...(manifest?.grants ? { grants: manifest.grants } : {}), problems };
}

function toJob(id, response) {
  if (response.pending) return { id, action: response.action, state: 'running', ...(response.error?.code === 'AWAITING_USER' ? { awaiting_user: true, error: response.error } : {}) };
  if (!response.ok) return { id, action: response.action, state: 'failed', error: response.error ?? { code: 'ACTION_FAILED', message: 'The action failed.' } };
  const artifacts = Array.isArray(response.artifacts) ? response.artifacts : [];
  const extra = artifacts.length || response.artifacts_skipped ? { artifacts, ...(response.artifacts_skipped ? { artifacts_skipped: response.artifacts_skipped } : {}) } : null;
  const plain = response.result && typeof response.result === 'object' && !Array.isArray(response.result);
  const result = !extra ? response.result : plain ? { ...response.result, ...extra } : { result: response.result, ...extra };
  return { id, action: response.action, state: 'succeeded', result };
}

// Speaks the socket's request shapes (actions, invoke, job) so the rest of the
// CLI, including waiting and error handling, needs no second code path.
export function bridgeTransport(directory, { env = process.env, now = () => Date.now() } = {}) {
  const launch = 'folder-bridge';
  const ready = async () => {
    const status = await bridgeStatus(directory, { now: now() });
    if (!status.ok) fail(status.problems[0].code, status.problems[0].message, status.problems[0].hint);
  };
  return async payload => {
    if (payload.method === 'actions') {
      await ready();
      const manifest = await json(path.join(directory, 'manifest.json'));
      if (!Array.isArray(manifest?.actions)) fail('INVALID_REPLY', 'manifest.json has no action list.');
      return { ok: true, launch_id: launch, result: { ...manifest, permissions: manifest.grants, transport: 'folder', artifacts_root: directory } };
    }
    if (payload.method === 'invoke') {
      if (!UUID.test(payload.id ?? '')) fail('INVALID_REQUEST', 'The folder bridge needs a UUID request id.');
      await ready();
      const body = { id: payload.id, action: payload.action, args: payload.arguments ?? {}, created: new Date(now()).toISOString(),
        ...(env.MYMAN_AGENT_TOKEN ? { credential: env.MYMAN_AGENT_TOKEN } : {}),
        ...(payload.machine_id ?? env.MYMAN_MACHINE_ID ? { machine_id: payload.machine_id ?? env.MYMAN_MACHINE_ID } : {}) };
      const text = JSON.stringify(body);
      if (Buffer.byteLength(text) > 1024 * 1024) fail('TOO_LARGE', 'Action arguments exceed 1 MiB.');
      // A dot name is never read by the app. The rename makes the request appear whole.
      const temporary = path.join(directory, 'inbox', `.${payload.id}.json.tmp`);
      await mkdir(path.join(directory, 'inbox'), { recursive: true });
      await writeFile(temporary, text, { flag: 'wx', mode: 0o600 });
      await rename(temporary, path.join(directory, 'inbox', `${payload.id}.json`));
      return { ok: true, launch_id: launch, job: { id: payload.id, action: payload.action, state: 'running' } };
    }
    if (payload.method === 'job') {
      if (!UUID.test(payload.id ?? '')) fail('INVALID_REQUEST', 'A UUID job id is required.');
      const outbox = path.join(directory, 'outbox', `${payload.id}.json`);
      const answered = response => response && typeof response.ok === 'boolean';
      const first = await json(outbox);
      if (answered(first)) return { ok: true, launch_id: launch, job: toJob(payload.id, first) };
      // Still queued: the request is in inbox/. The app writes the result before it removes
      // the request, so a request that has left inbox/ may already have its result.
      if (await exists(path.join(directory, 'inbox', `${payload.id}.json`))) return { ok: true, launch_id: launch, job: { id: payload.id, state: 'running' } };
      const late = await json(outbox);
      if (answered(late)) return { ok: true, launch_id: launch, job: toJob(payload.id, late) };
      // Taken and being run: the app logged it but has not written a result yet.
      if (await auditKnows(directory, payload.id)) return { ok: true, launch_id: launch, job: { id: payload.id, state: 'running' } };
      fail('JOB_NOT_FOUND', 'No request or result with this id is in the bridge folder. Results are kept for a day.');
    }
    fail('UNSUPPORTED', 'This command is not available through the folder bridge. Read outbox/ and audit.log in the bridge folder.');
  };
}
