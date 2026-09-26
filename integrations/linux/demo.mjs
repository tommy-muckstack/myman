import { execFile, spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { noteEvents } from './recording.mjs';
import { capture, screens } from './images.mjs';
import { parseTsv } from './desktop.mjs';
import { command, fail, imageCommand, run, unsupported } from './system.mjs';

// myman demo: one command from a steps file to a finished, polished demo.
// It opens the app, records it, performs each step with xdotool, then polishes
// the recording (auto-zoom, drawn cursor, backdrop, music, title and end
// cards). Recording and polishing run through the ordinary record commands, so
// the same "recording" permission applies. Every choice is plain JSON.
const exec = promisify(execFile);
const SCRIPT_KEYS = ['app', 'window', 'region', 'steps', 'title', 'end', 'polish', 'close', 'focus', 'max_duration'];
const STEP_KINDS = ['wait', 'move', 'click', 'type', 'key', 'scroll'];
const STEP_KEYS = { wait: [], move: ['seconds'], click: ['seconds', 'button', 'double'], type: ['cps', 'at'], key: [], scroll: [] };
export const DEFAULT_POLISH = { zoom: { auto: true }, cursor: { size: 'big' }, background: 'dusk', music: 'upbeat' };
const LEAD_IN = 0.8, LEAD_OUT = 1.2;

const bad = message => fail('INVALID_ARGUMENTS', message);
const number = (v, lo, hi, name) => { if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) bad(`${name} must be a number from ${lo} to ${hi}.`); return v; };
const point = (v, name) => { if (!Array.isArray(v) || v.length !== 2) bad(`${name} must be [x, y] inside the recorded area.`); return [number(v[0], 0, 16000, `${name}[0]`), number(v[1], 0, 16000, `${name}[1]`)]; };
function words(v, name) {
  if (typeof v === 'string') { const argv = v.trim().split(/\s+/).filter(Boolean); if (!argv.length) bad(`${name} is empty.`); return argv; }
  if (Array.isArray(v) && v.length && v.every(a => typeof a === 'string' && a.length)) return v;
  bad(`${name} must be a command line such as "gnome-calculator" or a list like ["xterm", "-fa", "Mono"].`);
}
// Validate a steps file and fill defaults. Unknown keys are errors, never ignored.
export function parseScript(script, { app } = {}) {
  if (!script || typeof script !== 'object' || Array.isArray(script)) bad('The demo script must be a JSON object with "steps".');
  const extra = Object.keys(script).filter(k => !SCRIPT_KEYS.includes(k));
  if (extra.length) bad(`The demo script has unknown key ${extra[0]}. Allowed: ${SCRIPT_KEYS.join(', ')}.`);
  if (!Array.isArray(script.steps) || !script.steps.length || script.steps.length > 200) bad('"steps" must be a list of 1 to 200 steps.');
  const steps = script.steps.map((s, i) => {
    const at = `steps[${i}]`;
    if (!s || typeof s !== 'object' || Array.isArray(s)) bad(`${at} must be an object such as {"click": [120, 80]}.`);
    const kinds = Object.keys(s).filter(k => STEP_KINDS.includes(k));
    if (kinds.length !== 1) bad(`${at} needs exactly one of ${STEP_KINDS.join(', ')}.`);
    const kind = kinds[0], other = Object.keys(s).filter(k => k !== kind && !STEP_KEYS[kind].includes(k));
    if (other.length) bad(`${at} has unknown key ${other[0]}. A ${kind} step allows: ${[kind, ...STEP_KEYS[kind]].join(', ') }.`);
    const v = s[kind];
    if (kind === 'wait') return { wait: number(v, 0, 30, `${at}.wait`) };
    if (kind === 'move') return { move: point(v, `${at}.move`), seconds: s.seconds === undefined ? 0.6 : number(s.seconds, 0, 5, `${at}.seconds`) };
    if (kind === 'click') {
      if (s.double !== undefined && typeof s.double !== 'boolean') bad(`${at}.double must be true or false.`);
      return { click: point(v, `${at}.click`), seconds: s.seconds === undefined ? 0.6 : number(s.seconds, 0, 5, `${at}.seconds`), button: s.button === undefined ? 1 : number(s.button, 1, 3, `${at}.button`), double: s.double === true };
    }
    if (kind === 'type') { if (typeof v !== 'string' || !v.length || v.length > 2000) bad(`${at}.type must be text of 1 to 2000 characters.`); return { type: v, cps: s.cps === undefined ? 14 : number(s.cps, 2, 60, `${at}.cps`), ...(s.at !== undefined ? { at: point(s.at, `${at}.at`) } : {}) }; }
    if (kind === 'key') { if (typeof v !== 'string' || !/^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*$/.test(v)) bad(`${at}.key must be a key or combination such as "Return" or "ctrl+s".`); return { key: v }; }
    return { scroll: Math.trunc(number(v, -50, 50, `${at}.scroll`)) || bad(`${at}.scroll must not be 0.`) };
  });
  const cmd = app !== undefined ? words(app, '--app') : script.app === undefined ? null : words(script.app, '"app"');
  if (script.window !== undefined && (typeof script.window !== 'string' || !script.window || script.window.length > 200)) bad('"window" must be part of the app window\'s title.');
  let region = script.region ?? (cmd || script.window ? 'window' : 'display');
  if (Array.isArray(region)) { if (region.length !== 4) bad('"region" must be "window", "display" or [x, y, width, height].'); region = region.map((n, k) => number(n, k < 2 ? 0 : 16, 16000, `region[${k}]`)); }
  else if (!['window', 'display'].includes(region)) bad('"region" must be "window", "display" or [x, y, width, height].');
  if (region === 'window' && !cmd && !script.window) bad('"region": "window" needs "app" or "window".');
  let polish = null;
  if (script.polish !== false) {
    if (script.polish !== undefined && (typeof script.polish !== 'object' || script.polish === null || Array.isArray(script.polish))) bad('"polish" must be a recipe object like record polish takes, or false.');
    polish = { ...DEFAULT_POLISH, ...(script.polish || {}) };
    if (!script.polish?.zoom) polish.zoom = 'steps';
    for (const k of ['title', 'end']) if (script[k] !== undefined) polish[k] = script[k];
  }
  const seconds = steps.reduce((t, s) => t + (s.wait ?? 0) + (s.seconds ?? 0) + (s.type ? s.type.length / s.cps : 0) + (s.click ? (s.double ? 0.25 : 0.15) : 0) + (s.key || s.scroll ? 0.2 : 0), LEAD_IN + LEAD_OUT);
  const max = script.max_duration === undefined ? Math.min(600, Math.ceil(seconds * 1.5 + 10)) : number(script.max_duration, 5, 600, '"max_duration"');
  if (seconds > max) bad(`The steps take about ${Math.round(seconds)} s, longer than max_duration ${max}.`);
  if (script.close !== undefined && typeof script.close !== 'boolean') bad('"close" must be true or false.');
  if (script.focus !== undefined && typeof script.focus !== 'boolean') bad('"focus" must be true or false.');
  const focus = script.focus !== false && Boolean(cmd || script.window);
  return { app: cmd, window: script.window ?? null, region, steps, polish, close: script.close !== false, focus, hides_other_windows: focus, estimated_seconds: +seconds.toFixed(1), max_duration: max };
}

// record start takes global coordinates with a bottom-left origin (as on the
// Mac); X11 windows and xdotool use a top-left origin.
export const toGlobal = ([x, y, w, h], desktop) => [x, desktop.height - y - h, w, h].map(Math.round);
// The demo knows what it did, so it zooms where it acted: on each click, and on
// each typing burst (at "at", or where it last clicked).
export function stepMoments(timed, typing) {
  const moments = timed.filter(r => r.e === 'click').map(r => ({ start: Math.max(0, r.t - 0.5), end: r.t + 1, x: r.x, y: r.y }));
  for (const g of typing) {
    const keys = timed.slice(g.from, g.from + g.count);
    if (g.focus && keys.length) moments.push({ start: Math.max(0, keys[0].t - 0.3), end: keys[keys.length - 1].t + 0.8, x: g.focus[0], y: g.focus[1] });
  }
  return moments.sort((a, b) => a.start - b.start).slice(0, 40);
}
// "focus" keeps the demo on one app: other ordinary windows are minimized while
// it records, then restored. Panels, docks and the desktop are never touched.
// _NET_CLIENT_LIST lists the window manager's top-level windows.
export const clientIds = xprop => (/#\s*(.*)$/m.exec(xprop)?.[1] ?? '').split(',').map(v => v.trim()).filter(v => /^0x[0-9a-f]+$/i.test(v)).map(v => String(parseInt(v, 16)));
// Hide a window only when it is an ordinary, visible window other than the one being demoed.
export const hideable = ({ id, type, state }, keep) => !keep.has(id) && (!type || /_NET_WM_WINDOW_TYPE_(NORMAL|DIALOG)\b/.test(type)) && !/_NET_WM_STATE_HIDDEN/.test(state || '');
async function xprop(args) { try { return (await exec('xprop', args, { timeout: 5000 })).stdout; } catch { return ''; } }
export async function hideOthers(keepIds) {
  if (!(await command('xprop'))) return { hidden: [], active: null, warning: 'Install xprop so the demo can hide other windows; they stay visible.' };
  const ids = clientIds(await xprop(['-root', '_NET_CLIENT_LIST']));
  if (!ids.length) return { hidden: [], active: null, warning: 'The window manager lists no windows, so other windows stay visible.' };
  const active = (await xdo('getactivewindow').catch(() => ({ stdout: '' }))).stdout.trim() || null;
  const keep = new Set(keepIds), hidden = [];
  for (const id of ids) {
    const props = await xprop(['-id', id, '_NET_WM_WINDOW_TYPE', '_NET_WM_STATE']);
    const type = /_NET_WM_WINDOW_TYPE\(ATOM\) = (.*)/.exec(props)?.[1], state = /_NET_WM_STATE\(ATOM\) = (.*)/.exec(props)?.[1];
    if (!hideable({ id, type, state }, keep)) continue;
    try { await xdo('windowminimize', id); hidden.push(id); } catch {}
  }
  if (hidden.length) await sleep(0.3);
  return { hidden, active };
}
export async function restoreOthers({ hidden = [], active = null } = {}) {
  for (const id of hidden) await xdo('windowmap', id).catch(() => {});
  if (active) await xdo('windowactivate', active).catch(() => {});
}
const cliPath = () => path.join(path.dirname(fileURLToPath(import.meta.url)), 'cli.mjs');
async function myman(args) {
  let out;
  try { out = (await exec(process.execPath, [cliPath(), ...args, '--json'], { env: process.env, timeout: 35 * 60_000, maxBuffer: 32 * 1024 * 1024 })).stdout; }
  catch (error) { out = error.stdout; if (!out) throw error; }
  let r; try { r = JSON.parse(out); } catch { fail('BACKEND_FAILED', `myman ${args.slice(0, 2).join(' ')} returned no result.`); }
  if (r.ok === false || r.error) fail(r.error?.code || r.code || 'BACKEND_FAILED', r.error?.message || r.message || `myman ${args.slice(0, 2).join(' ')} failed.`);
  return r;
}
const xdo = (...args) => exec('xdotool', args.map(String), { timeout: 60_000 });
const sleep = s => new Promise(r => setTimeout(r, s * 1000));
async function windowIds(pattern) { try { return (await xdo('search', '--onlyvisible', '--name', pattern)).stdout.split('\n').filter(Boolean); } catch { return []; } }
// The window's position on screen. xwininfo reports the true top-left;
// xdotool's geometry can be shifted by the window-manager frame.
async function windowRect(id) {
  if (await command('xwininfo')) {
    const { stdout } = await exec('xwininfo', ['-id', id], { timeout: 5000 }).catch(() => ({ stdout: '' }));
    const v = k => Number(new RegExp(`${k}:\\s+(-?\\d+)`).exec(stdout)?.[1]);
    if (/IsViewable/.test(stdout) && Number.isFinite(v('Absolute upper-left X'))) return [v('Absolute upper-left X'), v('Absolute upper-left Y'), v('Width'), v('Height')];
    return null;
  }
  const g = (await xdo('getwindowgeometry', '--shell', id).catch(() => ({ stdout: '' }))).stdout;
  const v = k => Number(new RegExp(`${k}=(-?\\d+)`).exec(g)?.[1]);
  return Number.isFinite(v('WIDTH')) ? [v('X'), v('Y'), v('WIDTH'), v('HEIGHT')] : null;
}
async function findWindow({ window, before }) {
  const pattern = window ? window.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : '.';
  for (let i = 0; i < 60; i++) {
    const ids = (await windowIds(pattern)).filter(id => window || !before.has(id));
    for (const id of ids.reverse()) {
      const rect = await windowRect(id);
      if (rect && rect[2] >= 64 && rect[3] >= 64) return { id, rect };
    }
    await sleep(0.25);
  }
  fail('NOT_FOUND', window ? `No visible window with "${window}" in its title appeared within 15 seconds.` : 'The app opened no new window within 15 seconds. Pass "window" with part of its title.');
}
// Ease the pointer along a curve so the drawn cursor glides like a person's.
async function glide(from, to, seconds) {
  const n = Math.max(1, Math.round(seconds * 40));
  for (let i = 1; i <= n; i++) {
    const k = i / n, e = k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2;
    await xdo('mousemove', Math.round(from[0] + (to[0] - from[0]) * e), Math.round(from[1] + (to[1] - from[1]) * e));
    if (n > 1) await sleep(seconds / n);
  }
}
const pointer = async () => { const { stdout } = await xdo('getmouselocation', '--shell'); return [Number(/X=(-?\d+)/.exec(stdout)[1]), Number(/Y=(-?\d+)/.exec(stdout)[1])]; };

export async function demo({ script: file, app, dryRun = false }) {
  if (typeof file !== 'string' || !file) bad('Pass --script with a steps file (JSON). See myman demo --help.');
  let raw; try { raw = file.trim().startsWith('{') ? file : await readFile(file, 'utf8'); } catch { bad(`Could not read the steps file ${file}.`); }
  let json; try { json = JSON.parse(raw); } catch { bad('The steps file is not valid JSON.'); }
  const plan = parseScript(json, { app });
  if (dryRun) return { ok: true, dry_run: true, ...plan, note: 'Coordinates are relative to the top-left of the recorded area (the app window by default).' };
  const desktop = await screens();
  if (desktop.session === 'wayland') unsupported('myman demo drives the app with xdotool, which needs X11 for now. On Wayland (Omarchy, Sway) record with myman record start and polish with myman record polish.');
  if (!(await command('xdotool'))) fail('DEPENDENCY_MISSING', 'Install xdotool to run demo steps.');
  const before = new Set(await windowIds('.'));
  let child = null, session = null, target = null, shown = null;
  try {
    if (plan.app) {
      child = spawn(plan.app[0], plan.app.slice(1), { detached: true, stdio: 'ignore', env: process.env });
      const ok = await new Promise(r => { child.once('spawn', () => r(true)); child.once('error', () => r(false)); });
      if (!ok) fail('NOT_FOUND', `Could not start ${plan.app[0]}.`);
      child.unref();
    }
    let rect;
    if (plan.region === 'window') target = await findWindow({ window: plan.window, before });
    else if (plan.focus) target = await findWindow({ window: plan.window, before }).catch(() => null);
    if (plan.focus && target) shown = await hideOthers([target.id]);
    if (target) { await xdo('windowactivate', '--sync', target.id).catch(() => {}); await sleep(0.4); }
    if (plan.region === 'window') rect = target.rect;
    else if (Array.isArray(plan.region)) rect = plan.region;
    const [ox, oy] = rect ? rect : [0, 0];
    await xdo('mousemove', ox + Math.round((rect?.[2] ?? 200) / 2), oy + Math.round((rect?.[3] ?? 200) / 2));
    const started = await myman(['record', 'start', '--hide-cursor', '--max-duration', String(plan.max_duration), ...(rect ? ['--region', toGlobal(rect, desktop).join(',')] : [])]);
    session = started.session_id;
    const events = [], typing = []; let last = null;
    await sleep(LEAD_IN);
    for (const s of plan.steps) {
      if (s.wait !== undefined) await sleep(s.wait);
      else if (s.move || s.click) {
        const [x, y] = s.move || s.click, to = [ox + x, oy + y];
        await glide(await pointer(), to, s.seconds);
        if (s.click) {
          last = [x, y];
          events.push({ e: 'click', x, y, b: s.button, at: Date.now() });
          await xdo('click', ...(s.double ? ['--repeat', 2, '--delay', 120] : []), s.button);
          await sleep(0.15);
        }
      } else if (s.type) {
        const delay = Math.round(1000 / s.cps), at = Date.now();
        typing.push({ from: events.length, count: s.type.length, focus: s.at ?? last });
        [...s.type].forEach((_, i) => events.push({ e: 'key', at: at + i * delay }));
        await xdo('type', '--delay', delay, '--', s.type);
      } else if (s.key) { events.push({ e: 'key', at: Date.now() }); await xdo('key', '--', s.key); await sleep(0.2); }
      else if (s.scroll) { const n = Math.abs(s.scroll); await xdo('click', '--repeat', n, '--delay', 60, s.scroll > 0 ? 5 : 4); await sleep(0.2); }
    }
    const timed = await noteEvents(session, events);
    await sleep(LEAD_OUT);
    const recorded = await myman(['record', 'stop', '--session-id', session]); session = null;
    const hid = shown?.hidden.length ?? 0, warning = plan.focus && !target ? 'The app window was not found, so other windows stayed visible.' : shown?.warning;
    await restoreOthers(shown); shown = null;
    const result = { ok: true, recording_id: recorded.id, steps_run: plan.steps.length, clicks: events.filter(e => e.e === 'click').length, region: rect ?? 'display', hidden_windows: hid, ...(warning ? { warning } : {}) };
    if (!plan.polish) return { ...result, id: recorded.id, video_path: recorded.video_path, note: `Polish it with myman record polish --id ${recorded.id} --json.` };
    const recipe = { ...plan.polish };
    if (recipe.zoom === 'steps') recipe.zoom = { moments: stepMoments(timed, typing) };
    if (!recipe.zoom?.moments?.length && plan.polish.zoom === 'steps') delete recipe.zoom;
    const polished = await myman(['record', 'polish', '--id', recorded.id, '--recipe', JSON.stringify(recipe)]);
    return { ...result, ...polished, recording_id: recorded.id, steps_run: plan.steps.length, note: `Raw recording kept as ${recorded.id}. ${polished.note ?? ''}`.trim() };
  } catch (error) {
    if (session) await myman(['record', 'cancel', '--session-id', session]).catch(() => {});
    throw error;
  } finally {
    if (shown) await restoreOthers(shown);
    if (plan.close && child?.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch { try { process.kill(child.pid, 'SIGTERM'); } catch {} } }
  }
}

// --look shows an agent the app before it writes steps: a picture of the
// window, and every piece of text it can click with the point to click, in the
// same coordinates the steps use (top-left of the window).
// OCR joins labels on one row (a toolbar, a row of buttons) into one line, so a
// line is split wherever the gap between words is wider than a space.
export function splitLine(line) {
  const words = [...(line.words || [])].sort((a, b) => a.rect[0] - b.rect[0]);
  if (words.length < 2) return [line];
  const gap = Math.max(8, line.rect[3] * 0.9), parts = [[words[0]]];
  for (const w of words.slice(1)) { const prev = parts.at(-1).at(-1); if (w.rect[0] - (prev.rect[0] + prev.rect[2]) > gap) parts.push([w]); else parts.at(-1).push(w); }
  if (parts.length === 1) return [line];
  return parts.map(ws => { const x0 = Math.min(...ws.map(w => w.rect[0])), y0 = Math.min(...ws.map(w => w.rect[1])), x1 = Math.max(...ws.map(w => w.rect[0] + w.rect[2])), y1 = Math.max(...ws.map(w => w.rect[1] + w.rect[3])); return { ...line, text: ws.map(w => w.text).join(' '), rect: [x0, y0, x1 - x0, y1 - y0], words: ws }; });
}
export function lookElements(lines, size) {
  return lines.flatMap(splitLine)
    .filter(l => l.confidence >= 0.45 && /[\p{L}\p{N}]/u.test(l.text) && l.rect[2] >= 4 && l.rect[3] >= 4)
    .filter(l => !size || (l.rect[0] < size[0] && l.rect[1] < size[1]))
    .slice(0, 150)
    .map(({ words, ...l }, i) => ({ n: i + 1, kind: 'text', text: l.text, click: [Math.round(l.rect[0] + l.rect[2] / 2), Math.round(l.rect[1] + l.rect[3] / 2)], rect: l.rect.map(Math.round), source: 'text' }));
}
// ImageMagick drawing for the numbered copy: a box round each element and its
// number beside it, so the picture and the list can be matched by eye.
// A faint grid every 50 points, labelled every 100, lets an agent read off the
// point for anything the list misses, such as an icon.
export function markArgs(elements, size) {
  const out = [];
  if (size) {
    const [w, h] = size;
    out.push('-stroke', 'rgba(0,150,255,0.22)', '-strokewidth', '1');
    for (let x = 50; x < w; x += 50) out.push('-draw', `line ${x},0 ${x},${h}`);
    for (let y = 50; y < h; y += 50) out.push('-draw', `line 0,${y} ${w},${y}`);
    out.push('-stroke', 'none', '-fill', '#0077aa', '-pointsize', '10');
    for (let x = 100; x < w; x += 100) out.push('-draw', `text ${x + 2},${h - 3} '${x}'`);
    for (let y = 100; y < h; y += 100) out.push('-draw', `text 2,${y - 2} '${y}'`);
  }
  out.push('-fill', 'none', '-stroke', '#ff2d95', '-strokewidth', '2');
  for (const e of elements) { const [x, y, w, h] = e.rect; out.push('-draw', `rectangle ${x - 2},${y - 2} ${x + w + 2},${y + h + 2}`); }
  out.push('-stroke', 'none', '-fill', '#ff2d95');
  for (const e of elements) { const [lx, ly] = labelAt(e.rect); out.push('-draw', `rectangle ${lx},${ly} ${lx + 8 + 8 * String(e.n).length},${ly + 14}`); }
  out.push('-fill', 'white', '-pointsize', '12');
  for (const e of elements) { const [lx, ly] = labelAt(e.rect); out.push('-draw', `text ${lx + 3},${ly + 11} '${e.n}'`); }
  return out;
}
// App text is small, so read it at twice the size, as scattered labels rather
// than a page, then scale the boxes back to window points.
// Apps mix dark and light panels, so it reads the picture twice, once as is and
// once inverted, and keeps each label once.
async function readUi(file, work) {
  const im = await imageCommand(), tess = await command('tesseract'), half = r => r.map(v => v / 2);
  const passes = [['ui-2x.png', []], ['ui-2x-inverted.png', ['-colorspace', 'Gray', '-negate']]];
  const found = await Promise.all(passes.map(async ([name, extra]) => {
    const big = path.join(work, name);
    await run(im, [file, '-filter', 'Lanczos', '-resize', '200%', ...extra, big]);
    const { stdout } = await run(tess, [big, 'stdout', '--psm', '11', 'tsv'], { timeout: 45_000, maxBuffer: 16 * 1024 * 1024 });
    return parseTsv(stdout, { words: true }).map(l => ({ ...l, rect: half(l.rect), words: l.words.map(w => ({ ...w, rect: half(w.rect) })) }));
  }));
  return mergeLines(found[0], found[1]);
}
// Keep every line from the first pass, plus lines from the second that don't overlap one.
export function mergeLines(first, second) {
  const overlaps = (a, b) => { const x = Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]), y = Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]); return x > 0 && y > 0 && x * y > 0.3 * Math.min(a[2] * a[3], b[2] * b[3]); };
  const out = [...first];
  for (const l of second) if (!out.some(o => overlaps(o.rect, l.rect))) out.push(l);
  return out.sort((a, b) => a.rect[1] - b.rect[1] || a.rect[0] - b.rect[0]);
}
const labelAt = ([x, y, , h]) => [Math.max(0, x - 4), y >= 16 ? y - 16 : y + h + 3];
const lookDir = () => path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'), 'myman', 'demo-look');

export async function look({ script: file, app, window }) {
  let json = {};
  if (file) { let raw; try { raw = file.trim().startsWith('{') ? file : await readFile(file, 'utf8'); } catch { bad(`Could not read the steps file ${file}.`); } try { json = JSON.parse(raw); } catch { bad('The steps file is not valid JSON.'); } }
  const cmd = app !== undefined ? words(app, '--app') : json.app === undefined ? null : words(json.app, '"app"');
  const title = window ?? json.window;
  if (!cmd && !title) bad('Pass --app with the app to look at (or --window with part of an open window\'s title).');
  if (title !== undefined && (typeof title !== 'string' || !title || title.length > 200)) bad('--window must be part of the app window\'s title.');
  const desktop = await screens();
  if (desktop.session === 'wayland') unsupported('myman demo --look needs X11 for now, like myman demo.');
  if (!(await command('xdotool'))) fail('DEPENDENCY_MISSING', 'Install xdotool to run demos.');
  const before = new Set(await windowIds('.'));
  let child = null;
  const work = await mkdtemp(path.join(os.tmpdir(), 'myman-look-'));
  try {
    if (cmd) {
      child = spawn(cmd[0], cmd.slice(1), { detached: true, stdio: 'ignore', env: process.env });
      const ok = await new Promise(r => { child.once('spawn', () => r(true)); child.once('error', () => r(false)); });
      if (!ok) fail('NOT_FOUND', `Could not start ${cmd[0]}.`);
      child.unref();
    }
    const target = await findWindow({ window: title ?? null, before });
    await xdo('windowactivate', '--sync', target.id).catch(() => {});
    await sleep(1);
    const rect = (await windowRect(target.id)) ?? target.rect;
    const shot = await capture({ region: toGlobal(rect, desktop) }, work);
    const lines = (await command('tesseract')) ? await readUi(shot.file, work) : null;
    const elements = lines ? lookElements(lines, [shot.width, shot.height]) : [];
    const dir = lookDir(); await mkdir(dir, { recursive: true, mode: 0o700 });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-'), screenshot = path.join(dir, `${stamp}.png`), numbered = path.join(dir, `${stamp}-numbered.png`);
    await rename(shot.file, screenshot).catch(async () => { await run(await imageCommand(), [shot.file, screenshot]); });
    await run(await imageCommand(), [screenshot, ...markArgs(elements, [shot.width, shot.height]), numbered]);
    const name = (await xdo('getwindowname', target.id).catch(() => ({ stdout: '' }))).stdout.trim();
    return {
      ok: true, app: cmd, window: { title: name, size: [rect[2], rect[3]] }, coordinates: 'points from the top-left of the app window, the same as demo steps',
      screenshot, numbered_screenshot: numbered, elements, element_source: lines ? 'on-screen text (OCR). Icons and some labels on dark or busy backgrounds are not listed; read their points off the grid in the numbered screenshot' : 'none: install tesseract to list clickable text',
      next: 'Write steps that click the "click" points of the elements you need, check them with myman demo --script steps.json --dry-run, then run myman demo. The app is opened fresh for the demo, in the same state as this picture.',
    };
  } finally {
    await rm(work, { recursive: true, force: true }).catch(() => {});
    if (child?.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch { try { process.kill(child.pid, 'SIGTERM'); } catch {} } }
  }
}
