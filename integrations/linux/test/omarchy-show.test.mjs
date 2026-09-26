import test from 'node:test';
import assert from 'node:assert/strict';
import { lstat, mkdir, mkdtemp, readFile, stat, symlink, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const here = path.dirname(new URL(import.meta.url).pathname);
// Omarchy's menu accepts JSONC: comments and trailing commas.
const jsonc = text => JSON.parse(text.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m, s) => s ?? '').replace(/,(\s*[}\]])/g, '$1'));
const userBindings = 'o.bind("SUPER + RETURN", "Terminal", "uwsm app -- ghostty")\n';
const userMenu = '{\n  // my own rows\n  "trigger.mine": { "label": "Mine", "action": "echo hi" },\n}\n';

test('myman omarchy install adds one key binding and menu, keeps user content, and remove restores it', async () => {
  const home = await mkdtemp(path.join(tmpdir(), 'myman-omarchy-'));
  process.env.XDG_CONFIG_HOME = path.join(home, 'config');
  delete process.env.HYPRLAND_INSTANCE_SIGNATURE;
  const real = path.join(home, 'dotfiles', 'bindings.lua'), bindings = path.join(home, 'config/hypr/bindings.lua'), menu = path.join(home, 'config/omarchy/extensions/omarchy-menu.jsonc');
  await mkdir(path.dirname(real), { recursive: true }); await mkdir(path.dirname(bindings), { recursive: true }); await mkdir(path.dirname(menu), { recursive: true });
  await writeFile(real, userBindings); await chmod(real, 0o644); await symlink(real, bindings); await writeFile(menu, userMenu);
  const omarchy = await import('../omarchy.mjs');
  await omarchy.install({ skipCheck: true });
  const result = await omarchy.install({ skipCheck: true });
  assert.equal(result.binding_installed, true); assert.equal(result.menu_installed, true);
  const lua = await readFile(real, 'utf8');
  assert.equal(lua.split('>>> myman').length - 1, 1, 'installing twice leaves one block');
  assert.ok(lua.startsWith(userBindings));
  assert.match(lua, /o\.bind\("SUPER \+ SHIFT \+ PRINT", "Show my agents part of the screen \(MyMan\)", ".+ show"\)/);
  assert.ok((await lstat(bindings)).isSymbolicLink(), 'a symlinked dotfile stays a symlink');
  assert.equal((await stat(real)).mode & 0o777, 0o644, 'file mode is kept');
  const rows = jsonc(await readFile(menu, 'utf8'));
  assert.equal(rows['trigger.mine'].label, 'Mine');
  assert.equal(rows['trigger.myman'].label, 'MyMan');
  assert.match(rows['trigger.myman.show'].action, / show$/);
  await omarchy.remove({ skipCheck: true });
  assert.equal(await readFile(real, 'utf8'), userBindings);
  assert.equal(await readFile(menu, 'utf8'), userMenu);
  // A fresh machine gets a new, valid menu file.
  process.env.XDG_CONFIG_HOME = path.join(home, 'fresh');
  await omarchy.install({ skipCheck: true });
  assert.ok(jsonc(await readFile(path.join(home, 'fresh/omarchy/extensions/omarchy-menu.jsonc'), 'utf8'))['trigger.myman.brain']);
});

test('only a person at an interactive terminal can change Omarchy config or use myman show', () => {
  const run = (args, env = {}) => JSON.parse(spawnSync(process.execPath, [path.join(here, '../cli.mjs'), ...args, '--json'], { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] }).stdout.toString());
  assert.equal(run(['omarchy', 'install']).error.code, 'HUMAN_REQUIRED');
  assert.equal(run(['omarchy', 'remove']).error.code, 'HUMAN_REQUIRED');
  assert.equal(run(['show'], { MYMAN_AGENT_TOKEN: 'x' }).error.code, 'HUMAN_REQUIRED');
});

test('a shown capture is described for agents with the person\'s note', async () => {
  const { describeCapture } = await import('../library.mjs');
  const d = describeCapture({ width: 400, height: 250, region: '0,0,400,250', shown: true, note: 'this button is misaligned' });
  assert.equal(d.heading, 'Shown to agents: this button is misaligned');
  assert.match(d.alt_text, /^Screenshot the person selected to show their agents: this button is misaligned, 400x250 pixels/);
});
