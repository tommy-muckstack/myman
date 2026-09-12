import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { lstat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import catalog from './actions.json' with { type: 'json' };
import { BrainError } from './brain.mjs';
export { catalog };

export async function request(payload, { socketPath = `/tmp/myman-${process.getuid()}/control.sock`, timeout = 15000 } = {}) {
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
export async function invoke(action, args = {}, { id = randomUUID(), wait = true, transport = request, waitMs = 300000 } = {}) {
  describe(action);
  const first = await transport({ method: 'invoke', id, action, arguments: args });
  if (!wait) return first;
  const deadline = Date.now() + waitMs;
  let reply = first;
  while (reply.job?.state === 'running' && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 200));
    reply = await transport({ method: 'job', id });
    if (reply.launch_id !== first.launch_id) throw new BrainError('APP_RESTARTED', `App restarted; job ${id} cannot be verified. Do not replay automatically.`);
  }
  return reply;
}
