// `myman omarchy install|remove|status`: add or remove MyMan's key binding and
// menu in Omarchy. Both live in the person's own files as one clearly marked
// block, so a rerun replaces it, removal leaves everything else untouched, and
// the person can read or edit it. A person's command: it refuses to run inside
// an agent or without an interactive terminal.
import { homedir } from 'node:os';
import { chmod, mkdir, readFile, realpath, rename, stat, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { command, fail, rootPath, run, configPath } from './system.mjs';

const start = '-- >>> myman (added by `myman omarchy install`; remove with `myman omarchy remove`)', end = '-- <<< myman';
const jStart = '  // >>> myman (added by `myman omarchy install`; remove with `myman omarchy remove`)', jEnd = '  // <<< myman';
export const key = 'SUPER + SHIFT + PRINT';
const paths = () => {
  const config = process.env.XDG_CONFIG_HOME || path.join(homedir(), '.config');
  return { bindings: path.join(config, 'hypr', 'bindings.lua'), menu: path.join(config, 'omarchy', 'extensions', 'omarchy-menu.jsonc') };
};
const quote = s => `'${String(s).replaceAll("'", `'\\''`)}'`;
async function launcher() {
  // Hyprland may not have ~/.local/bin on PATH, so use absolute paths.
  const found = await command('myman');
  return found ? quote(found) : `${quote(process.execPath)} ${quote(fileURLToPath(new URL('./cli.mjs', import.meta.url)))}`;
}
async function read(file) { try { return await readFile(file, 'utf8'); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } }
// Dotfiles are often symlinks into a repo (stow, chezmoi): write through the
// link to the real file and keep its mode, replacing it atomically.
async function atomic(file, text) {
  let target = file, mode = 0o644;
  try { target = await realpath(file); mode = (await stat(target)).mode & 0o777; } catch (error) { if (error.code !== 'ENOENT') throw error; await mkdir(path.dirname(file), { recursive: true }); }
  const temp = path.join(path.dirname(target), `.myman-${randomUUID()}.tmp`);
  await writeFile(temp, text, { mode }); await chmod(temp, mode); await rename(temp, target);
}
function strip(text, a, b) {
  const i = text.indexOf(a); if (i < 0) return text;
  const j = text.indexOf(b, i); if (j < 0) fail('INVALID_CONFIG', 'Found the start of the MyMan block but not its end. Fix the file by hand, then rerun.');
  return text.slice(0, i) + text.slice(j + b.length).replace(/^\n/, '');
}
const lua = s => JSON.stringify(s); // Lua accepts JSON-style double-quoted strings with these escapes.
function bindingBlock(cmd) {
  return [start, `o.bind(${lua(key)}, "Show my agents part of the screen (MyMan)", ${lua(cmd + ' show')})`, end].join('\n');
}
function menuBlock(cmd) {
  const term = c => `omarchy-launch-floating-terminal-with-presentation ${quote(c)}`;
  const rows = {
    'trigger.myman': { icon: '󰚩', label: 'MyMan' },
    'trigger.myman.show': { icon: '', label: 'Show my agents part of the screen', action: `${cmd} show` },
    'trigger.myman.brain': { icon: '', label: 'Open MyMan Brain folder', action: `xdg-open ${quote(rootPath())}` },
    'trigger.myman.doctor': { icon: '', label: 'Check MyMan setup', action: term(`${cmd} doctor`) },
    'trigger.myman.permissions': { icon: '', label: 'Edit agent permissions', action: `omarchy-launch-editor ${quote(configPath())}` },
    'trigger.myman.dictation': { icon: '', label: 'Save my dictations to the Brain', action: term(`${cmd} dictation connect`) },
    'trigger.myman.agents': { icon: '', label: 'List agent credentials', action: term(`${cmd} agents list`) },
  };
  return [jStart, ...Object.entries(rows).map(([k, v]) => `  ${JSON.stringify(k)}: ${JSON.stringify(v)},`), jEnd].join('\n');
}
function person() {
  if (process.env.MYMAN_AGENT_TOKEN || !process.stdin.isTTY || !process.stdout.isTTY) fail('HUMAN_REQUIRED', 'Only the person at this computer can change Omarchy key bindings and menus, from an interactive terminal (not from an agent).');
}
async function reload() {
  const done = [];
  const menu = await command('omarchy-menu'); if (menu) { try { await run(menu, ['refresh'], { timeout: 3000 }); done.push('menu'); } catch {} }
  const hypr = await command('hyprctl'); if (hypr && process.env.HYPRLAND_INSTANCE_SIGNATURE) { try { await run(hypr, ['reload'], { timeout: 3000 }); done.push('hyprland'); } catch {} }
  return done;
}
export async function status() {
  const p = paths(), b = await read(p.bindings), m = await read(p.menu);
  return { key, binding_installed: !!b?.includes(start), menu_installed: !!m?.includes(jStart), bindings_file: p.bindings, menu_file: p.menu };
}
export async function install({ skipCheck = false } = {}) {
  if (!skipCheck) person();
  const p = paths(), cmd = await launcher();
  const b = strip((await read(p.bindings)) ?? '', start, end);
  await atomic(p.bindings, `${b.replace(/\s*$/, '')}${b.trim() ? '\n\n' : ''}${bindingBlock(cmd)}\n`);
  let m = strip((await read(p.menu)) ?? '{\n}\n', jStart, jEnd);
  const open = m.indexOf('{'); if (open < 0) fail('INVALID_CONFIG', `${p.menu} has no top-level object. Fix it by hand, then rerun.`);
  // JSONC allows trailing commas, so our rows can lead the object.
  m = m.slice(0, open + 1) + '\n' + menuBlock(cmd) + m.slice(open + 1);
  await atomic(p.menu, m);
  return { ...(await status()), reloaded: await reload(), next: `Press ${key} and drag over what you want your agents to see. The menu is under Trigger, then MyMan.` };
}
export async function remove({ skipCheck = false } = {}) {
  if (!skipCheck) person();
  const p = paths(), b = await read(p.bindings), m = await read(p.menu);
  if (b?.includes(start)) await atomic(p.bindings, strip(b, start, end).replace(/\s*$/, '\n'));
  if (m?.includes(jStart)) await atomic(p.menu, strip(m, jStart, jEnd));
  return { ...(await status()), reloaded: await reload() };
}
