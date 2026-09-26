// Theme-aware markup defaults. On Omarchy, annotations without an explicit
// color use the active theme (~/.local/state/omarchy/current/theme/colors.toml),
// so an agent's screenshots match the user's desktop. Explicit colors always win.
// MYMAN_MARKUP_THEME=none turns this off; =/path/to/colors.toml pins a file.
import { homedir } from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';

const hex = /^#[0-9a-fA-F]{6}$/;
export const fallback = { arrow: '#FF375F', box: '#FF375F', highlight: '#FF375F', text: '#FF375F' };
export function parseColors(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const m = /^\s*([a-z_]+)\s*=\s*"([^"]*)"\s*(?:#.*)?$/.exec(line);
    if (m) out[m[1]] = m[2];
  }
  return out;
}
// Attention colors for pointers, the theme accent for framing and labels.
export function roles(colors) {
  const pick = (...keys) => keys.map(k => colors[k]).find(v => hex.test(v ?? ''));
  const accent = pick('accent', 'blue');
  if (!accent) return null;
  return { arrow: pick('red', 'bright_red') ?? accent, box: accent, highlight: pick('yellow', 'bright_yellow') ?? accent, text: accent };
}
export function candidates(env = process.env) {
  const state = env.XDG_STATE_HOME || path.join(homedir(), '.local/state'), config = env.XDG_CONFIG_HOME || path.join(homedir(), '.config');
  return [path.join(state, 'omarchy/current/theme'), path.join(config, 'omarchy/current/theme')];
}
export async function markupTheme(env = process.env) {
  const setting = env.MYMAN_MARKUP_THEME;
  if (setting === 'none') return { name: null, source: 'default', colors: fallback };
  const dirs = setting && setting !== 'omarchy' && setting !== 'auto' ? [path.dirname(setting)] : candidates(env);
  for (const dir of dirs) {
    try {
      const file = setting && dirs.length === 1 && setting.endsWith('.toml') ? setting : path.join(dir, 'colors.toml');
      const colors = roles(parseColors((await readFile(file, 'utf8')).slice(0, 64 * 1024)));
      if (!colors) continue;
      let name = null; try { name = (await readFile(path.join(dir, '..', 'theme.name'), 'utf8')).trim().slice(0, 100) || null; } catch {}
      return { name, source: 'omarchy', colors };
    } catch {}
  }
  return { name: null, source: 'default', colors: fallback };
}
