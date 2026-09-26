import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { BrainError } from '../brain/brain.mjs';

export function procIdentity(stat, bootID) {
  // comm (field 2) may contain spaces and parentheses. The last closing
  // parenthesis precedes field 3; starttime is field 22, not a split-on-space index.
  const end = stat.lastIndexOf(')');
  const fields = end < 0 ? [] : stat.slice(end+1).trim().split(/\s+/);
  if (fields.length < 20 || !/^\d+$/.test(fields[19]) || !/^[0-9a-f-]{36}$/i.test(bootID.trim())) throw new BrainError('PROCESS_IDENTITY_UNAVAILABLE', 'Cannot parse the Linux worker identity.');
  if (['Z','X','x'].includes(fields[0])) return null;
  return { boot_id: bootID.trim(), start_ticks: fields[19] };
}
export async function processIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return null;
  if (process.platform !== 'linux') {
    // Development-only portable contract tests. The installer rejects non-Linux
    // hosts, and the marketplace dispatcher uses the untouched Mac companion.
    try { process.kill(pid,0); const {stdout}=await promisify(execFile)('/bin/ps',['-p',String(pid),'-o','lstart='],{timeout:2000});return stdout.trim()?{development_host:process.platform,start_time:stdout.trim()}:null; } catch { return null; }
  }
  try {
    const [stat,boot]=await Promise.all([readFile(`/proc/${pid}/stat`,'utf8'),readFile('/proc/sys/kernel/random/boot_id','utf8')]);
    return procIdentity(stat,boot);
  } catch (error) {
    if (['ENOENT','ESRCH'].includes(error.code)) return null;
    if (error instanceof BrainError) throw error;
    throw new BrainError('PROCESS_IDENTITY_UNAVAILABLE', 'Cannot read the Linux worker identity; no PID-only liveness claim is made.');
  }
}
export async function workerAlive(receipt) {
  if (!receipt.pid || !receipt.process_identity) return false;
  const current=await processIdentity(receipt.pid);
  return current!==null && JSON.stringify(current)===JSON.stringify(receipt.process_identity);
}
