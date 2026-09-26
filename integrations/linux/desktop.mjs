// Linux implementations of read-mostly desktop actions agents rely on:
// OCR with line boxes, the window list, and the clipboard. Each one fails
// with unsupported_on_platform when the desktop session has no backend,
// rather than returning a partial or invented answer.
import { spawn } from 'node:child_process';
import path from 'node:path';
import { command, fail, readSafe, run, unsupported } from './system.mjs';
import { screens } from './images.mjs';

const session = () => process.env.WAYLAND_DISPLAY ? 'wayland' : 'x11';

// Tesseract TSV rows are words; group them into lines with pixel rectangles
// in the same top-left image coordinates screenshot.edit accepts.
export function parseTsv(tsv, { words = false } = {}) {
  const lines = new Map();
  for (const row of tsv.split('\n').slice(1)) {
    const c = row.split('\t');
    if (c.length < 12 || c[0] !== '5') continue;
    const text = c.slice(11).join('\t').trim(), conf = Number(c[10]);
    if (!text || conf < 0) continue;
    const [left, top, width, height] = c.slice(6, 10).map(Number), key = c.slice(1, 5).join('.');
    const line = lines.get(key) || { words: [], x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity, conf: [] };
    line.words.push(text); line.conf.push(conf); (line.boxes ||= []).push({ text, rect: [left, top, width, height] });
    line.x0 = Math.min(line.x0, left); line.y0 = Math.min(line.y0, top);
    line.x1 = Math.max(line.x1, left + width); line.y1 = Math.max(line.y1, top + height);
    lines.set(key, line);
  }
  return [...lines.values()].map((l, i) => ({ id: `line-${i + 1}`, text: l.words.join(' '), rect: [l.x0, l.y0, l.x1 - l.x0, l.y1 - l.y0], granularity: 'line', confidence: Math.round(l.conf.reduce((a, b) => a + b, 0) / l.conf.length) / 100, ...(words ? { words: l.boxes } : {}) }));
}
export async function ocrRegions(file, width, height) {
  const tool = await command('tesseract');
  if (!tool) fail('DEPENDENCY_MISSING', 'Install tesseract to read text from screenshots.');
  const { stdout } = await run(tool, [file, 'stdout', 'tsv'], { timeout: 45_000, maxBuffer: 16 * 1024 * 1024 });
  const regions = parseTsv(stdout).map(r => ({ ...r, box: [r.rect[0] / width, r.rect[1] / height, r.rect[2] / width, r.rect[3] / height], box_coordinates: 'normalized-top-left' }));
  return { text: regions.map(r => r.text).join('\n'), coordinates: 'image-pixels-top-left', regions };
}

const prop = (text, name) => { const m = text.match(new RegExp(`^${name}\\([^)]*\\) = (.*)$`, 'm')); return m ? m[1] : null; };
const unquote = value => value ? [...value.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map(m => m[1].replace(/\\(.)/g, '$1')) : [];
// Compositor layout coordinates (top-left, may be negative) become the same
// normalized desktop space screenshots use; region is ready for --region.
export function placeWindow(win, desktop) {
  const [ox, oy] = desktop.origin ?? [0, 0], [x, y, w, h] = win.frame, nx = x - ox, ny = y - oy;
  // Clip to the display holding the window's centre so region always fits
  // one display, as screenshot --region requires.
  const cx = nx + w / 2, cy = ny + h / 2;
  const d = desktop.displays?.find(d => cx >= d.x && cy >= d.y && cx < d.x + d.width && cy < d.y + d.height);
  const base = { ...win, coordinates: desktop.session === 'wayland' ? 'compositor-layout-top-left' : 'x11-global-top-left' };
  if (!d) return { ...base, region: null, region_coordinates: 'global-bottom-left', offscreen: true };
  const x0 = Math.max(nx, d.x), y0 = Math.max(ny, d.y), x1 = Math.min(nx + w, d.x + d.width), y1 = Math.min(ny + h, d.y + d.height);
  return { ...base, display: d.selector, region: [x0, desktop.height - y1, x1 - x0, y1 - y0], region_coordinates: 'global-bottom-left', ...(x0 !== nx || y0 !== ny || x1 !== nx + w || y1 !== ny + h ? { clipped: true } : {}) };
}
export function hyprlandWindows(clients, monitors) {
  const visible = new Set((monitors ?? []).flatMap(m => [m.activeWorkspace?.id, m.specialWorkspace?.id]).filter(id => id !== undefined && id !== 0));
  return (Array.isArray(clients) ? clients : [])
    .filter(c => c.mapped && !c.hidden && Array.isArray(c.at) && Array.isArray(c.size) && (!visible.size || visible.has(c.workspace?.id)))
    .sort((a, b) => (a.focusHistoryID ?? 1e9) - (b.focusHistoryID ?? 1e9))
    .map(c => ({ id: String(c.address), app: c.class || c.initialClass || '', title: c.title || '', pid: c.pid > 0 ? c.pid : null, frame: [...c.at, ...c.size], workspace: c.workspace?.name ?? null, floating: !!c.floating, focused: c.focusHistoryID === 0 }));
}
export function swayWindows(tree) {
  const out = [];
  const walk = (node, workspace) => {
    if (node.type === 'workspace') workspace = node.name;
    if ((node.type === 'con' || node.type === 'floating_con') && node.pid && node.visible) out.push({ id: String(node.id), app: node.app_id || node.window_properties?.class || '', title: node.name || '', pid: node.pid, frame: [node.rect.x, node.rect.y, node.rect.width, node.rect.height], workspace: workspace ?? null, floating: node.type === 'floating_con', focused: !!node.focused });
    for (const child of [...(node.nodes ?? []), ...(node.floating_nodes ?? [])]) walk(child, workspace);
  };
  walk(tree ?? {}, null);
  return out.sort((a, b) => b.focused - a.focused);
}
async function waylandWindows(desktop) {
  const json = async (tool, args) => { try { return JSON.parse((await run(tool, args)).stdout); } catch { fail('BACKEND_FAILED', `${path.basename(tool)} returned no window data.`); } };
  if (desktop.compositor === 'hyprland') {
    const hyprctl = await command('hyprctl');
    return hyprlandWindows(await json(hyprctl, ['-j', 'clients']), await json(hyprctl, ['-j', 'monitors']));
  }
  if (desktop.compositor === 'sway') return swayWindows(await json(await command('swaymsg'), ['-r', '-t', 'get_tree']));
  unsupported('windows.list on Wayland supports Hyprland (including Omarchy) and Sway.');
}
export async function windowsList() {
  const desktop = await screens();
  if (desktop.session === 'wayland') return (await waylandWindows(desktop)).slice(0, 200).map(w => placeWindow(w, desktop));
  const xprop = await command('xprop'), xwininfo = await command('xwininfo');
  if (!xprop || !xwininfo) fail('DEPENDENCY_MISSING', 'Install xprop and xwininfo (x11-utils) to list windows.');
  const root = (await run(xprop, ['-root', '_NET_CLIENT_LIST_STACKING'])).stdout;
  const ids = (root.match(/0x[0-9a-f]+/gi) || []).slice(-200).reverse(); // front-most first
  const windows = [];
  for (const id of ids) {
    let props, info;
    try { props = (await run(xprop, ['-id', id, 'WM_CLASS', '_NET_WM_NAME', 'WM_NAME', '_NET_WM_PID'])).stdout; info = (await run(xwininfo, ['-id', id])).stdout; } catch { continue; } // window closed mid-scan
    if (!/Map State: IsViewable/.test(info)) continue;
    const num = label => Number((info.match(new RegExp(`${label}:\\s+(-?\\d+)`)) || [])[1]);
    const [x, y, w, h] = [num('Absolute upper-left X'), num('Absolute upper-left Y'), num('Width'), num('Height')];
    const cls = unquote(prop(props, 'WM_CLASS')), title = unquote(prop(props, '_NET_WM_NAME'))[0] ?? unquote(prop(props, 'WM_NAME'))[0] ?? '';
    const pid = Number(prop(props, '_NET_WM_PID')) || null;
    windows.push(placeWindow({ id: String(parseInt(id, 16)), app: cls[1] || cls[0] || '', title, pid, frame: [x, y, w, h], focused: windows.length === 0 }, desktop));
  }
  return windows;
}

async function clipTool(write) {
  if (session() === 'wayland') {
    const tool = await command(write ? 'wl-copy' : 'wl-paste');
    if (!tool) fail('DEPENDENCY_MISSING', 'Install wl-clipboard for clipboard access on Wayland.');
    return { tool, kind: 'wl' };
  }
  const tool = await command('xclip');
  if (!tool) fail('DEPENDENCY_MISSING', 'Install xclip for clipboard access on X11.');
  return { tool, kind: 'xclip' };
}
const pasteArgs = (kind, type) => kind === 'wl' ? ['--no-newline', ...(type ? ['--type', type] : [])] : ['-selection', 'clipboard', '-o', ...(type ? ['-t', type] : [])];
async function paste(type, encoding) {
  const { tool, kind } = await clipTool(false);
  try { return (await run(tool, pasteArgs(kind, type), { timeout: 10_000, encoding, maxBuffer: 12 * 1024 * 1024 })).stdout; }
  catch { return null; } // No owner or no data in that format.
}
export async function clipboardRead({ format }) {
  if (format === 'text') { const text = await paste(null, 'utf8'); return { text: text ?? null, change_count: null }; }
  const targets = (await paste(session() === 'wayland' ? null : 'TARGETS', 'utf8')) ?? '';
  const { kind } = await clipTool(false);
  const types = kind === 'wl' ? ((await run((await clipTool(false)).tool, ['--list-types'], { timeout: 10_000 }).catch(() => ({ stdout: '' }))).stdout) : targets;
  if (!/^image\/png$/m.test(types)) fail('NOT_FOUND', 'Clipboard has no image.');
  const png = await paste('image/png', 'buffer');
  if (!png?.length) fail('NOT_FOUND', 'Clipboard has no image.');
  if (png.length > 8 * 1024 * 1024) fail('TOO_LARGE', 'Clipboard image exceeds 8 MiB.');
  return { image: { mimeType: 'image/png', data: png.toString('base64') }, change_count: null };
}
// xclip and wl-copy fork a background owner that serves the selection;
// the foreground process exits once it has read the input.
async function copy(data, type) {
  const { tool, kind } = await clipTool(true);
  const args = kind === 'wl' ? ['--type', type] : ['-selection', 'clipboard', '-t', type, '-i'];
  await new Promise((resolve, reject) => {
    const child = spawn(tool, args, { stdio: ['pipe', 'ignore', 'ignore'] });
    const timer = setTimeout(() => { child.kill(); reject(Object.assign(new Error('clipboard timed out'), { code: 'PROCESSING_TIMEOUT' })); }, 10_000);
    child.on('error', reject);
    child.on('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(Object.assign(new Error('clipboard write failed'), { code: 'BACKEND_FAILED' })); });
    child.stdin.end(data);
  }).catch(error => fail(error.code || 'BACKEND_FAILED', `${path.basename(tool)} could not write the clipboard. Check doctor and desktop access.`));
}
export async function clipboardWrite(args, captureEntry) {
  if ((args.text === undefined) === (args.id === undefined)) fail('INVALID_ARGUMENTS', 'Supply exactly one of text or id.');
  if (args.text !== undefined) { if (args.format === 'image') fail('INVALID_ARGUMENTS', 'Text cannot be copied as an image.'); await copy(args.text, session() === 'wayland' ? 'text/plain;charset=utf-8' : 'UTF8_STRING'); return { copied: true, format: 'text', characters: args.text.length }; }
  const entry = await captureEntry(args.id);
  if (args.format === 'text') { await copy(entry.image_path, session() === 'wayland' ? 'text/plain;charset=utf-8' : 'UTF8_STRING'); return { copied: true, format: 'text', id: args.id, path: entry.image_path }; }
  await copy(await readSafe(entry.image_path, 64 * 1024 * 1024), 'image/png');
  return { copied: true, format: 'image', id: args.id, path: entry.image_path };
}

// Capture one window by the id windows.list returned. The window must sit on
// a single display; the capture is the visible frame, not hidden contents.
export async function windowRegion(id) {
  const win = (await windowsList()).find(w => w.id === String(id));
  if (!win) fail('UNKNOWN_WINDOW', 'No visible window with that ID. Run windows list for current IDs.');
  if (!win.region) fail('INVALID_ARGUMENTS', 'That window is off-screen.');
  return win;
}

// Raw OCR lines with word boxes, for targets and comparison.
export async function ocrLines(file) {
  const tool = await command('tesseract');
  if (!tool) fail('DEPENDENCY_MISSING', 'Install tesseract to read text from screenshots.');
  const { stdout } = await run(tool, [file, 'stdout', 'tsv'], { timeout: 45_000, maxBuffer: 16 * 1024 * 1024 });
  return parseTsv(stdout, { words: true });
}
