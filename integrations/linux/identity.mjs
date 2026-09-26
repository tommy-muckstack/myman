// Named agent credentials, matching AgentIdentity.swift on the Mac. Only a
// person issues them (`myman agents add` at a real terminal); nothing in the
// action catalog, MCP server or app server can create, revoke or widen one.
// Credentials tell cooperating agents apart. Like the Mac, they do not sandbox
// processes running under the same login; grants and /etc policy still cap
// every action, and a credential's scopes can only narrow them.
import { mkdir, rmdir } from 'node:fs/promises';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { hostname } from 'node:os';
import path from 'node:path';
import { atomic, configPath, directory, fail, readSafe } from './system.mjs';

export const scopesAvailable = ['capture', 'markup', 'recording', 'library', 'microphone'];
export const registryPath = () => path.join(path.dirname(configPath()), 'identities.json');
const digest = token => createHash('sha256').update(token).digest('hex');

async function load() {
  try {
    const data = JSON.parse((await readSafe(registryPath(), 1024 * 1024, true)).toString());
    if (!data || typeof data.machine_id !== 'string' || !Array.isArray(data.agents)) throw new SyntaxError('shape');
    return data;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    fail('IDENTITY_UNAVAILABLE', `Cannot read the agent registry at ${registryPath()}. Fix or remove it with myman agents at a terminal.`);
  }
}
async function change(fn) {
  await directory(path.dirname(registryPath()), true, true);
  const lock = registryPath() + '.lock';
  for (let i = 0; ; i++) {
    try { await mkdir(lock, { mode: 0o700 }); break; }
    catch (error) { if (error.code !== 'EEXIST' || i > 100) fail('BUSY', 'The agent registry is locked; try again.'); await new Promise(r => setTimeout(r, 50)); }
  }
  try {
    const state = (await load()) ?? { machine_id: randomUUID(), required: false, agents: [] };
    const result = await fn(state);
    await atomic(registryPath(), JSON.stringify(state, null, 2));
    return result;
  } finally { await rmdir(lock).catch(() => {}); }
}

export async function machine() {
  let state = await load();
  if (!state) state = await change(s => s);
  return { id: state.machine_id, name: hostname() || 'This computer', transport: 'local_cli', remote_execution: 'provided_by_host' };
}
export async function checkMachine(target) {
  if (!target) return;
  const here = await machine();
  if (target !== here.id) { const error = new Error('This is a different computer. Select the intended host before retrying.'); error.code = 'WRONG_MACHINE'; error.details = { machine: here }; throw error; }
}

const local = { id: 'local', name: 'Local client', scopes: scopesAvailable, named: false };
let current = local;
// The principal for this process: the credential in MYMAN_AGENT_TOKEN, or the
// local client when there is none (refused once the person requires names).
export async function authenticate(token = process.env.MYMAN_AGENT_TOKEN) {
  const state = await load();
  if (!token) {
    if (state?.required) fail('IDENTITY_REQUIRED', 'Named agent credentials are required here. Ask the person at this computer to run myman agents add NAME, then set MYMAN_AGENT_TOKEN.');
    return current = local;
  }
  const agent = state?.agents.find(a => !a.revoked && a.digest === digest(token));
  if (!agent) fail('INVALID_CREDENTIAL', 'Agent credential is invalid or revoked.');
  return current = { id: agent.id, name: agent.name, scopes: agent.scopes, named: true };
}
export function principal() { return current; }
// Owner for timers and other per-agent state. Unnamed agents keep the older
// MYMAN_AGENT_ID label so existing timers stay controllable.
export function actorId() { return current.named ? current.id : (process.env.MYMAN_AGENT_ID || 'agent').slice(0, 120); }
export function validate(who, permissions) {
  const missing = permissions.filter(p => !who.scopes.includes(p));
  if (missing.length) fail('AGENT_SCOPE_DENIED', `This agent's credential does not include ${missing.join(', ')}. Only the person at this computer can issue a wider one.`);
}
export async function registered(id, scope) {
  const state = await load();
  return !!state?.agents.some(a => a.id === id && !a.revoked && (!scope || a.scopes.includes(scope)));
}
export async function directoryList() {
  return ((await load())?.agents ?? []).filter(a => !a.revoked).map(a => ({ id: a.id, name: a.name }));
}

// Human-only management. The CLI calls these only after confirming a person
// is at an interactive terminal; they are never catalog actions.
export async function listAll() {
  const state = await load();
  return { registry: registryPath(), required: state?.required ?? false, machine: await machine(), agents: (state?.agents ?? []).map(({ digest: _, ...a }) => a) };
}
export async function issue(name, scopes) {
  name = String(name ?? '').trim();
  if (!name || name.length > 80) fail('INVALID_ARGUMENTS', 'Use an agent name of 1 to 80 characters.');
  if (!scopes.length || scopes.some(s => !scopesAvailable.includes(s))) fail('INVALID_ARGUMENTS', `Scopes must be some of: ${scopesAvailable.join(', ')}.`);
  const token = randomBytes(32).toString('base64url');
  const agent = await change(state => {
    if (state.agents.length >= 100) fail('INVALID_ARGUMENTS', 'At most 100 registrations are kept.');
    const value = { id: randomUUID(), name, scopes: [...new Set(scopes)].sort(), digest: digest(token), revoked: false, created_at: new Date().toISOString() };
    state.agents.push(value); state.required = true;
    return value;
  });
  const { digest: _, ...shown } = agent;
  return { agent: shown, token, required: true };
}
export async function revoke(id) {
  return change(state => {
    const agent = state.agents.find(a => a.id === id || a.name === id);
    if (!agent) fail('NOT_FOUND', 'No agent with that ID or name.');
    agent.revoked = true; return { revoked: agent.id };
  });
}
export async function setRequired(value) { return change(state => { state.required = value; return { required: value }; }); }
