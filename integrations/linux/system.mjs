import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { access, lstat, mkdir, open, readFile, realpath, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { BrainError } from '../brain/brain.mjs';

export const fail = (code, message) => { throw new BrainError(code, message); };
export const unsupported = message => fail('unsupported_on_platform', message);
export const rootPath = () => {
  const root = process.env.MYMAN_BRAIN_ROOT || path.join(homedir(), 'MyManBrain');
  if (!path.isAbsolute(root) || /[\x00-\x1f]/.test(root)) fail('INVALID_ROOT', 'Brain root must be an absolute path without control characters.');
  return path.resolve(root);
};
export const configPath = () => path.join(process.env.XDG_CONFIG_HOME || path.join(homedir(), '.config'), 'myman', 'agents.json');
export const statePath = () => path.join(process.env.XDG_STATE_HOME || path.join(homedir(), '.local/state'), 'myman');
export const defaultGrants = { enabled: false, capture: false, markup: false, recording: false, library: false };
export async function command(name) {
  for (const dir of (process.env.PATH || '').split(path.delimiter).filter(p => path.isAbsolute(p))) {
    const file = path.join(dir, name);
    try { await access(file, constants.X_OK); if ((await lstat(file)).isFile() || (await lstat(file)).isSymbolicLink()) return file; } catch {}
  }
  return null;
}
export async function run(file, args, options = {}) {
  try { return await promisify(execFile)(file, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024, encoding: 'utf8', ...options }); }
  catch (error) { fail(error.killed ? 'PROCESSING_TIMEOUT' : 'BACKEND_FAILED', `${path.basename(file)} failed${error.killed ? ' or timed out' : ''}. Check doctor and desktop access.`); }
}
// Refuse linked ancestors, including a pre-existing private state/config directory.
export async function directory(dir, create = true, privateDir = false) {
  if (!path.isAbsolute(dir)) fail('INVALID_PATH', 'Use an absolute path.');
  if (create) {
    let ancestor = dir;
    while (true) {
      try { if (await realpath(ancestor) !== ancestor) fail('UNSAFE_PATH', 'Linked directories are not supported.'); break; }
      catch (error) { if (error.code !== 'ENOENT') throw error; ancestor = path.dirname(ancestor); }
    }
    await mkdir(dir, { recursive: true, mode: 0o700 });
  }
  const info = await lstat(dir);
  if (!info.isDirectory() || info.isSymbolicLink() || await realpath(dir) !== dir) fail('UNSAFE_PATH', 'Linked directories are not supported.');
  if (privateDir && (info.uid !== process.getuid() || (info.mode & 0o077))) fail('UNSAFE_PATH', 'MyMan config/state directories must be owned by this login with mode 700.');
  return dir;
}
export async function readSafe(file, maxBytes = 8 * 1024 * 1024, privateFile = false) {
  await directory(path.dirname(file), false);
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.nlink > 1 || info.size > maxBytes || (privateFile && (info.uid !== process.getuid() || (info.mode & 0o077)))) fail('UNSAFE_PATH', 'Expected an owned, bounded, unlinked regular file (private files require mode 600).');
    const buffer = Buffer.alloc(info.size + 1);
    let bytesRead = 0;
    while (bytesRead < buffer.length) { const part = await handle.read(buffer, bytesRead, buffer.length - bytesRead, bytesRead); if (!part.bytesRead) break; bytesRead += part.bytesRead; }
    if (bytesRead !== info.size) fail('EXPORT_CHANGED', 'File changed while reading.');
    return buffer.subarray(0, bytesRead);
  } finally { await handle.close(); }
}
export async function atomic(file, value) {
  await directory(path.dirname(file));
  const temp = path.join(path.dirname(file), `.myman-${randomUUID()}.tmp`);
  const handle = await open(temp, 'wx', 0o600);
  try { await handle.writeFile(value); await handle.sync(); } finally { await handle.close(); }
  try { await rename(temp, file); } finally { await unlink(temp).catch(() => {}); }
}
export async function grants() {
  try {
    await directory(path.dirname(configPath()), false, true);
    const data = JSON.parse((await readSafe(configPath(), 16_384, true)).toString());
    if (!data || data.version !== 1 || !data.grants || Object.keys(data.grants).some(k => !Object.hasOwn(defaultGrants, k)) || Object.values(data.grants).some(v => typeof v !== 'boolean')) fail('INVALID_CONFIG', 'Expected version 1 and boolean grants in agents.json.');
    return { ...defaultGrants, ...data.grants };
  } catch (error) {
    if (error.code === 'ENOENT') return { ...defaultGrants };
    if (error instanceof SyntaxError) fail('INVALID_CONFIG', 'agents.json must be valid JSON.');
    throw error;
  }
}
export async function authorize(permissions) {
  const settings = await grants();
  if (!settings.enabled) fail('AGENT_DISABLED', `Local commands are disabled. The owner can edit ${configPath()}.`);
  for (const permission of permissions) if (!settings[permission]) fail('AGENT_DISABLED', `The owner has not granted ${permission} access in ${configPath()}.`);
}
export async function dependencies() {
  const names = ['magick', 'convert', 'scrot', 'import', 'ffmpeg', 'grim', 'xdpyinfo', 'xrandr', 'tesseract', 'git'];
  return Object.fromEntries(await Promise.all(names.map(async name => [name, await command(name)])));
}
export async function imageCommand() {
  const file = await command('magick') || await command('convert');
  if (!file) fail('DEPENDENCY_MISSING', 'Install ImageMagick (magick or convert) for PNG capture and annotation.');
  return file;
}
export function pngSize(buffer) {
  if (buffer.length < 33 || !buffer.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || buffer.toString('ascii',12,16) !== 'IHDR') fail('INVALID_IMAGE', 'Expected a PNG image.');
  const width = buffer.readUInt32BE(16), height = buffer.readUInt32BE(20);
  if (!width || !height || width * height > 100_000_000) fail('IMAGE_TOO_LARGE', 'PNG exceeds 100 million pixels.');
  return { width, height };
}
