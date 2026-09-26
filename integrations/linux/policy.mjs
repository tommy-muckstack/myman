import { constants } from 'node:fs';
import { lstat, open, realpath } from 'node:fs/promises';
import path from 'node:path';
import { BrainError } from '../brain/brain.mjs';

// Deliberately fixed: an agent's environment or CLI flags cannot redirect or
// disable the administrator's ceiling. Absence preserves the user-only model.
export const systemPolicyPath = '/etc/myman/agents.json';
export const defaultGrants = { enabled: false, capture: false, markup: false, recording: false, library: false, microphone: false };
const invalid = message => { throw new BrainError('INVALID_SYSTEM_POLICY', message); };
export function parseGrants(text, code = 'INVALID_CONFIG') {
  let data;
  try { data = JSON.parse(text); } catch { throw new BrainError(code, 'Expected valid JSON for the grants policy.'); }
  if (!data || typeof data !== 'object' || Array.isArray(data) || data.version !== 1 || Object.keys(data).some(k=>!['version','grants'].includes(k)) || !data.grants || typeof data.grants !== 'object' || Array.isArray(data.grants) || Object.keys(data.grants).some(k=>!Object.hasOwn(defaultGrants,k)) || Object.values(data.grants).some(v=>typeof v!=='boolean')) {
    throw new BrainError(code, 'Expected version 1 and an object of boolean grants.');
  }
  return { ...defaultGrants, ...data.grants };
}
export function capGrants(user, system) {
  return Object.fromEntries(Object.keys(defaultGrants).map(key=>[key,user[key]===true && (system===null || system[key]===true)]));
}
export function checkPolicyOwner(info, directory = false) {
  if (info.uid !== 0 || (info.mode & 0o022) || info.isSymbolicLink() || !(directory ? info.isDirectory() : info.isFile()) || (!directory && info.nlink !== 1)) {
    invalid('System policy and its directories must be root-owned, unlinked, and not writable by group or others.');
  }
}
export async function systemGrants() {
  // Production calls this only on Linux. Mac contract tests have no /etc policy.
  if (process.platform !== 'linux') return null;
  let handle, observedPolicy = false;
  try {
    for (const dir of ['/', '/etc', path.dirname(systemPolicyPath)]) {
      const info = await lstat(dir);
      checkPolicyOwner(info, true);
      if (await realpath(dir) !== dir) invalid('Linked system policy directories are not supported.');
    }
    // Check lstat first so a dangling symlink cannot masquerade as no policy.
    checkPolicyOwner(await lstat(systemPolicyPath));
    observedPolicy = true;
    handle = await open(systemPolicyPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const before = await handle.stat();
    checkPolicyOwner(before);
    if (before.size > 16_384) invalid('System policy exceeds 16 KiB.');
    const buffer = Buffer.alloc(before.size + 1);
    let length = 0;
    while (length < buffer.length) { const part=await handle.read(buffer,length,buffer.length-length,length);if(!part.bytesRead)break;length+=part.bytesRead; }
    const after = await handle.stat(), current = await lstat(systemPolicyPath);
    checkPolicyOwner(current);
    if (length !== before.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs || before.ino !== current.ino || before.dev !== current.dev) invalid('System policy changed while reading; no permission was granted.');
    return parseGrants(buffer.subarray(0,length).toString(), 'INVALID_SYSTEM_POLICY');
  } catch (error) {
    if (error.code === 'ENOENT' && !handle && !observedPolicy) return null;
    if (error instanceof BrainError) throw error;
    invalid('System policy cannot be read safely; no permission was granted.');
  } finally { await handle?.close(); }
}
