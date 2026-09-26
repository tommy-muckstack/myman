import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DEFAULT_POLISH, clientIds, hideable, lookElements, markArgs, mergeLines, parseScript, splitLine, stepMoments, toGlobal } from '../demo.mjs';
import { BACKDROPS, drawCard, literalText, parseCard, parseRecipe } from '../studio.mjs';

const has = cmd => { try { execFileSync(cmd, ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } };
const invalid = e => e.code === 'INVALID_ARGUMENTS';

test('demo scripts: steps are strict, defaults are filled, polish defaults to the full look', () => {
  const p = parseScript({ app: 'gnome-calculator', title: 'Calculator in 10 seconds', steps: [{ wait: 0.5 }, { click: [120, 80] }, { type: '2+2', at: [60, 20] }, { key: 'Return' }, { scroll: -2 }, { move: [10, 10], seconds: 0 }] });
  assert.deepEqual(p.app, ['gnome-calculator']); assert.equal(p.region, 'window'); assert.equal(p.close, true);
  assert.deepEqual(p.steps[1], { click: [120, 80], seconds: 0.6, button: 1, double: false });
  assert.deepEqual(p.steps[2], { type: '2+2', cps: 14, at: [60, 20] });
  assert.deepEqual(p.polish, { ...DEFAULT_POLISH, zoom: 'steps', title: 'Calculator in 10 seconds' });
  assert.ok(p.estimated_seconds > 2 && p.max_duration >= p.estimated_seconds);
  assert.deepEqual(parseScript({ steps: [{ wait: 1 }] }, { app: ['xterm', '-fa', 'Mono'] }).app, ['xterm', '-fa', 'Mono']);
  assert.equal(parseScript({ steps: [{ wait: 1 }] }).region, 'display');
  assert.equal(parseScript({ steps: [{ wait: 1 }], polish: false }).polish, null);
  assert.deepEqual(parseScript({ steps: [{ wait: 1 }], polish: { zoom: { auto: true }, music: 'calm' } }).polish.zoom, { auto: true });
  // The polish recipe it builds is one record polish accepts.
  const { zoom, ...rest } = p.polish; assert.ok(parseRecipe(rest));
});

test('demo scripts reject anything unclear instead of guessing', () => {
  for (const s of [null, [], {}, { steps: [] }, { steps: [{}] }, { steps: [{ click: [1, 2], key: 'a' }] }, { steps: [{ click: [1] }] }, { steps: [{ wait: 99 }] }, { steps: [{ key: 'ctrl+s; rm -rf' }] }, { steps: [{ type: '' }] }, { steps: [{ scroll: 0 }] }, { steps: [{ wait: 1, speed: 2 }] }, { steps: [{ wait: 1 }], extra: 1 }, { steps: [{ wait: 1 }], region: 'window' }, { steps: [{ wait: 1 }], region: [0, 0, 5] }, { steps: [{ wait: 1 }], polish: 'yes' }, { steps: [{ wait: 20 }, { wait: 20 }], max_duration: 10 }, { app: '', steps: [{ wait: 1 }] }, { app: 'xterm', focus: 'yes', steps: [{ wait: 1 }] }])
    assert.throws(() => parseScript(s), invalid, JSON.stringify(s));
});

test('demo an app: other windows are hidden while it records, unless focus is false or there is no app', () => {
  assert.equal(parseScript({ app: 'xterm', steps: [{ wait: 1 }] }).focus, true);
  assert.equal(parseScript({ app: 'xterm', steps: [{ wait: 1 }] }).hides_other_windows, true);
  assert.equal(parseScript({ app: 'xterm', focus: false, steps: [{ wait: 1 }] }).focus, false);
  assert.equal(parseScript({ steps: [{ wait: 1 }] }).focus, false);
  assert.deepEqual(clientIds('_NET_CLIENT_LIST(WINDOW): window id # 0x1a00003, 0x2200007\n'), [String(0x1a00003), String(0x2200007)]);
  assert.deepEqual(clientIds(''), []);
  const keep = new Set(['7']);
  assert.equal(hideable({ id: '7', type: '_NET_WM_WINDOW_TYPE_NORMAL' }, keep), false);
  assert.equal(hideable({ id: '8', type: '_NET_WM_WINDOW_TYPE_NORMAL' }, keep), true);
  assert.equal(hideable({ id: '9' }, keep), true);
  for (const type of ['_NET_WM_WINDOW_TYPE_DOCK', '_NET_WM_WINDOW_TYPE_DESKTOP', '_NET_WM_WINDOW_TYPE_NOTIFICATION']) assert.equal(hideable({ id: '8', type }, keep), false, type);
  assert.equal(hideable({ id: '8', type: '_NET_WM_WINDOW_TYPE_NORMAL', state: '_NET_WM_STATE_HIDDEN' }, keep), false);
});

test('demo --look lists clickable text with the point to click, in window points', () => {
  const w = (text, x) => ({ text, rect: [x, 10, 40, 12] });
  const row = { text: 'Save Cancel', rect: [10, 10, 200, 12], confidence: 0.9, words: [w('Save', 10), w('Cancel', 170)] };
  assert.deepEqual(splitLine(row).map(l => l.text), ['Save', 'Cancel']);
  assert.deepEqual(splitLine({ ...row, words: [w('Add', 10), w('to', 54)] }).map(l => l.text), ['Save Cancel']);
  const els = lookElements([row, { text: '|', rect: [0, 0, 2, 20], confidence: 0.9 }, { text: 'blurry', rect: [0, 40, 30, 10], confidence: 0.2 }]);
  assert.deepEqual(els, [{ n: 1, kind: 'text', text: 'Save', click: [30, 16], rect: [10, 10, 40, 12], source: 'text' }, { n: 2, kind: 'text', text: 'Cancel', click: [190, 16], rect: [170, 10, 40, 12], source: 'text' }]);
  const a = { text: 'Play', rect: [10, 10, 30, 10] };
  assert.deepEqual(mergeLines([a], [{ text: 'Pla', rect: [11, 10, 30, 10] }, { text: 'Search', rect: [300, 10, 40, 10] }]).map(l => l.text), ['Play', 'Search']);
  const args = markArgs(els, [400, 300]);
  assert.ok(args.includes('rectangle 8,8 52,24'));
  assert.ok(args.includes("text 100,297 '100'") || args.some(v => v.startsWith('text 102,')));
  assert.ok(args.filter(v => String(v).startsWith('line ')).length === 7 + 5);
});

test('region coordinates convert from the top-left window origin to record start\'s bottom-left global origin', () => {
  assert.deepEqual(toGlobal([5, 29, 817, 382], { width: 1280, height: 800 }), [5, 389, 817, 382]);
});

test('the demo zooms where it acted: each click, and each typing burst at its focus point', () => {
  const timed = [{ t: 1, e: 'click', x: 100, y: 50 }, { t: 1.5, e: 'key' }, { t: 1.6, e: 'key' }, { t: 1.7, e: 'key' }, { t: 4, e: 'click', x: 300, y: 200 }];
  assert.deepEqual(stepMoments(timed, [{ from: 1, count: 3, focus: [400, 20] }]), [{ start: 0.5, end: 2, x: 100, y: 50 }, { start: 1.2, end: 2.5, x: 400, y: 20 }, { start: 3.5, end: 5, x: 300, y: 200 }]);
  assert.deepEqual(stepMoments([{ t: 0.2, e: 'key' }], [{ from: 0, count: 1, focus: null }]), []);
});

test('title and end cards: text or {text, subtitle, seconds}; text is only ever text', () => {
  assert.equal(parseCard(undefined, 'title', 2.5), null);
  assert.deepEqual(parseCard('Hello', 'title', 2.5), { text: 'Hello', subtitle: null, seconds: 2.5 });
  assert.deepEqual(parseCard({ text: 'Bye', subtitle: 'myman.dev', seconds: 3 }, 'end', 2), { text: 'Bye', subtitle: 'myman.dev', seconds: 3 });
  for (const c of ['', 'x'.repeat(81), 'a\nb\nc', 'bell\u0007', { text: 'a', color: 'red' }, { text: 'a', seconds: 30 }, 5]) assert.throws(() => parseCard(c, 'title', 2), invalid, JSON.stringify(c));
  // ImageMagick would read "@file" and expand "%" escapes; both come out literal.
  assert.equal(literalText('@/etc/passwd 100% %w a\\b'), '\\@/etc/passwd 100%% %%w a\\\\b');
});

test('cards render at the video size with the backdrop colours', { skip: !has('convert') }, async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'studio-card-'));
  try {
    const file = await drawCard(dir, 'title', { text: 'A long headline that has to shrink to fit the card', subtitle: 'subtitle' }, { width: 640, height: 360, colors: BACKDROPS.ocean });
    assert.equal(execFileSync('identify', ['-format', '%wx%h', file]).toString(), '640x360');
    const px = execFileSync('convert', [file, '-format', '%[pixel:p{2,2}]', 'info:']).toString();
    assert.match(px, /srgb\((7[0-9]|8[0-9]),(15[0-9]|16[0-9]),2[2-4][0-9]\)/, `top-left is the ocean start colour (${px})`);
    const edges = execFileSync('convert', [file, '-crop', '8x360+0+0', '-format', '%[fx:maxima.r]', 'info:']).toString();
    assert.ok(Number(edges) < 0.6, 'the headline does not run off the left edge');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a demo needs the control grant as well as recording; a dry run needs only recording', async () => {
  const { mkdtemp, mkdir, writeFile, realpath } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { spawnSync } = await import('node:child_process');
  const home = await mkdtemp(path.join(await realpath(tmpdir()), 'myman-demo-grant-'));
  const config = path.join(home, 'config/myman');
  await mkdir(config, { recursive: true, mode: 0o700 });
  await writeFile(path.join(config, 'agents.json'), JSON.stringify({ version: 1, grants: { enabled: true, recording: true } }), { mode: 0o600 });
  const env = { ...process.env, XDG_CONFIG_HOME: path.join(home, 'config'), XDG_STATE_HOME: path.join(home, 'state'), MYMAN_BRAIN_ROOT: path.join(home, 'brain') };
  delete env.MYMAN_AGENT_TOKEN;
  const cli = new URL('../cli.mjs', import.meta.url).pathname, script = JSON.stringify({ app: ['true'], steps: [{ wait: 0.1 }] });
  const run = args => JSON.parse(spawnSync(process.execPath, [cli, 'demo', '--script', script, ...args, '--json'], { env }).stdout.toString());
  const denied = run([]);
  assert.equal(denied.error.code, 'AGENT_DISABLED'); assert.match(denied.error.message, /control/);
  assert.equal(run(['--dry-run']).dry_run, true);
});
