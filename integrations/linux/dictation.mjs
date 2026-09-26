// Dictation on Linux rides on Voxtype, Omarchy's local (Whisper) dictation.
// `myman dictation connect` makes Voxtype pipe each dictation through
// `myman dictation save`, which passes the text straight back (so typing is
// never delayed or lost) and keeps a copy in the Brain's dictations folder.
import { mkdir, mkdtemp, readFile, realpath, rename, rm, stat, writeFile, chmod } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { command, fail, run } from './system.mjs';
import { saveDictation } from './library.mjs';

const start = '# >>> myman (added by `myman dictation connect`; remove with `myman dictation disconnect`)', end = '# <<< myman';
const base = () => process.env.XDG_CONFIG_HOME || path.join(homedir(), '.config');
const paths = () => ({ voxtype: path.join(base(), 'voxtype', 'config.toml'), state: path.join(base(), 'myman', 'voxtype.json') });
async function read(file) { try { return await readFile(file, 'utf8'); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } }
async function write(file, text, fallbackMode = 0o644) {
  let target = file, mode = fallbackMode;
  try { target = await realpath(file); mode = (await stat(target)).mode & 0o777; } catch (error) { if (error.code !== 'ENOENT') throw error; await mkdir(path.dirname(file), { recursive: true }); }
  const temp = path.join(path.dirname(target), `.myman-${randomUUID()}.tmp`);
  await writeFile(temp, text, { mode }); await chmod(temp, mode); await rename(temp, target);
}
function person() {
  if (process.env.MYMAN_AGENT_TOKEN || !process.stdin.isTTY || !process.stdout.isTTY) fail('HUMAN_REQUIRED', 'Only the person at this computer can connect dictation, from an interactive terminal (not from an agent).');
}
async function launcher() {
  const found = await command('myman');
  // Plain paths stay unquoted so the command reads the same with or without a shell.
  const quote = s => /^[\w@%+=:,./-]+$/.test(s) ? s : "'" + s.replaceAll("'", "'\\''") + "'";
  return found ? quote(found) : `${quote(process.execPath)} ${quote(new URL('./cli.mjs', import.meta.url).pathname)}`;
}
// Find the [output.post_process] table (lines up to the next table header).
function findTable(lines) {
  const i = lines.findIndex(l => /^\s*\[\s*output\.post_process\s*\]\s*(#.*)?$/.test(l));
  if (i < 0) return null;
  let j = i + 1; while (j < lines.length && !/^\s*\[/.test(lines[j])) j++;
  while (j > i + 1 && !lines[j - 1].trim()) j--;
  return [i, j];
}
function value(lines, key) {
  const line = lines.find(l => new RegExp(`^\\s*${key}\\s*=`).test(l)); if (!line) return undefined;
  const raw = line.replace(/^[^=]*=\s*/, '').trim();
  if (raw.startsWith('"')) { const m = raw.match(/^"(?:\\.|[^"\\])*"/); return m ? JSON.parse(m[0]) : undefined; }
  if (raw.startsWith("'")) { const m = raw.match(/^'([^']*)'/); return m?.[1]; }
  const n = Number(raw.split('#')[0].trim()); return Number.isFinite(n) ? n : undefined;
}
async function restartVoxtype() {
  const systemctl = await command('systemctl');
  if (!systemctl) return false;
  try { await run(systemctl, ['--user', 'is-active', '--quiet', 'voxtype'], { timeout: 3000 }); } catch { return false; }
  try { await run(systemctl, ['--user', 'restart', 'voxtype'], { timeout: 10000 }); return true; } catch { return false; }
}
async function connected() { try { return !!(await read(paths().voxtype))?.includes(start); } catch { return false; } }
export async function status() {
  const p = paths(), text = await read(p.voxtype), state = JSON.parse((await read(p.state)) ?? '{}');
  return { connected: !!text?.includes(start), voxtype_installed: !!(await command('voxtype')), voxtype_config: p.voxtype, chained_command: state.previous_command ?? null, saves_to: 'dictations/ in your MyMan Brain' };
}
export async function connect({ skipCheck = false } = {}) {
  if (!skipCheck) person();
  const p = paths(); let text = await read(p.voxtype);
  if (text === null) fail('NOT_FOUND', `Voxtype is not set up (${p.voxtype} is missing). On Omarchy, run omarchy-voxtype-install first.`);
  if (text.includes(start)) return { ...(await status()), already: true };
  const lines = text.split('\n'), table = findTable(lines);
  let previous = null, timeout = 0;
  if (table) {
    const body = lines.slice(table[0], table[1]);
    previous = { text: body.join('\n'), command: value(body, 'command') ?? null, timeout_ms: value(body, 'timeout_ms') ?? null };
    timeout = Number(previous.timeout_ms) || 0;
    lines.splice(table[0], table[1] - table[0]); text = lines.join('\n');
  }
  // Keep a person's own cleanup step: MyMan runs it first, then saves its output.
  await write(p.state, JSON.stringify({ version: 1, previous_command: previous?.command ?? null, previous_timeout_ms: previous?.timeout_ms ?? null, previous_table: previous?.text ?? null }, null, 2) + '\n', 0o600);
  const block = [start, '[output.post_process]', `command = ${JSON.stringify(`${await launcher()} dictation save`)}`, `timeout_ms = ${Math.max(10000, timeout + 5000)}`, end].join('\n');
  await write(p.voxtype, `${text.replace(/\s*$/, '')}\n\n${block}\n`);
  return { ...(await status()), restarted_voxtype: await restartVoxtype(), next: 'Dictate as usual (F9 or Super+Ctrl+X on Omarchy). Each dictation is typed as before and saved to your Brain.' };
}
export async function disconnect({ skipCheck = false } = {}) {
  if (!skipCheck) person();
  const p = paths(), text = await read(p.voxtype);
  if (text?.includes(start)) {
    const i = text.indexOf(start), j = text.indexOf(end, i);
    if (j < 0) fail('INVALID_CONFIG', 'Found the start of the MyMan block in the Voxtype config but not its end. Fix it by hand, then rerun.');
    let rest = (text.slice(0, i).replace(/\n*$/, '') + text.slice(j + end.length).replace(/^\n+/, '\n')).replace(/\s*$/, '\n');
    const state = JSON.parse((await read(p.state)) ?? '{}');
    if (state.previous_table) rest = `${rest.replace(/\s*$/, '')}\n\n${state.previous_table}\n`;
    await write(p.voxtype, rest);
    await write(p.state, JSON.stringify({ version: 1 }, null, 2) + '\n', 0o600);
  }
  return { ...(await status()), restarted_voxtype: await restartVoxtype() };
}
function readStdin() { return new Promise((resolve, reject) => { const chunks = []; process.stdin.on('data', c => chunks.push(c)); process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString())); process.stdin.on('error', reject); }); }
function pipe(cmd, input, timeoutMs) {
  return new Promise(resolve => {
    const child = spawn('/bin/sh', ['-c', cmd], { stdio: ['pipe', 'pipe', 'ignore'] }), out = [];
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve(null); }, timeoutMs);
    child.stdout.on('data', c => out.push(c)); child.on('error', () => { clearTimeout(timer); resolve(null); });
    child.on('close', code => { clearTimeout(timer); resolve(code === 0 ? Buffer.concat(out).toString() : null); });
    child.stdin.end(input);
  });
}
// Called by Voxtype with the dictated text on stdin. It must print the text
// back even if anything else fails, and never adds its own output.
export async function save() {
  const original = await readStdin();
  let text = original;
  try {
    const state = JSON.parse((await read(paths().state)) ?? '{}');
    if (state.previous_command) text = (await pipe(state.previous_command, original, Number(state.previous_timeout_ms) || 30000)) ?? original;
  } catch {}
  // Voxtype waits for this process to exit before typing, so print the text,
  // hand the Brain save to a detached process, and exit right away.
  await new Promise(resolve => process.stdout.write(text, resolve));
  // Save only after the person opted in with myman dictation connect; otherwise pass through.
  if (process.env.MYMAN_AGENT_TOKEN || !text.trim() || !(await connected())) return;
  try {
    const dir = await mkdtemp(path.join(process.env.XDG_RUNTIME_DIR || tmpdir(), 'myman-dictation-'));
    const file = path.join(dir, 'text'); await writeFile(file, text, { mode: 0o600 });
    spawn(process.execPath, [process.argv[1], 'dictation', 'store', file], { detached: true, stdio: 'ignore' }).unref();
  } catch {}
}
// Background half of save: store the text, then delete the private temp copy.
export async function store(file) {
  const dir = path.dirname(file);
  if (!path.basename(dir).startsWith('myman-dictation-') || path.basename(file) !== 'text') return;
  if (!(await connected())) { await rm(dir, { recursive: true, force: true }); return; }
  try {
    const text = await readFile(file, 'utf8');
    for (let attempt = 0; attempt < 20; attempt++) {
      try { await saveDictation({ text, source: 'voxtype' }); return; }
      catch (error) { if (error.code !== 'LIBRARY_BUSY') return; await new Promise(r => setTimeout(r, 300)); }
    }
  } finally { await rm(dir, { recursive: true, force: true }); }
}
