import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { BACKDROPS, FPS, LEVELS, MAX_RIPPLES, backgroundChain, backgroundLayout, drawBackground, parseBackground, SIZES, YELLOW, cursorChain, cursorCommands, cursorFrames, level, parseCursor, parseRecipe, zoomExpressions, zoomGraph, zoomPlan } from '../studio.mjs';

const size = { width: 800, height: 600, duration: 20 };
const has = cmd => { try { execFileSync(cmd, ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } };

test('recipes are strict JSON: named or numeric levels, unknown keys rejected', () => {
  assert.equal(level('subtle'), LEVELS.subtle); assert.equal(level(undefined), LEVELS.normal); assert.equal(level('2.2'), 2.2);
  assert.deepEqual(parseRecipe({}), { zoom: null, cursor: null, background: null });
  const r = parseRecipe({ zoom: { auto: true, level: 'strong' } });
  assert.equal(r.zoom.auto, true); assert.equal(r.zoom.level, 2.4); assert.equal(r.zoom.ramp, 0.6);
  const m = parseRecipe({ zoom: { moments: [{ start: 1, end: 2, x: 10, y: 20, level: 3 }] } });
  assert.equal(m.zoom.auto, false); assert.equal(m.zoom.moments[0].level, 3);
  const bad = [{ music: {} }, { zoom: { speed: 2 } }, { zoom: { level: 9 } }, { zoom: { level: 'huge' } }, { zoom: { moments: [{ start: 2, end: 1, x: 0, y: 0 }] } }, { zoom: { moments: [{ start: 0, end: 1, x: 0 }] } }, { zoom: { moments: [{ start: 0, end: 1, x: 0, y: 0, rect: [] }] } }, { zoom: [] }];
  for (const recipe of bad) assert.throws(() => parseRecipe(recipe), e => e.code === 'INVALID_ARGUMENTS', JSON.stringify(recipe));
});

test('nearby moments share one zoom and pan; far ones zoom out between; short ones get room to ease', () => {
  const plan = zoomPlan([{ start: 4, end: 5, x: 600, y: 400 }, { start: 1, end: 3, x: 100, y: 100 }, { start: 12, end: 12.3, x: 900, y: -5 }], size);
  assert.equal(plan.length, 2);
  assert.deepEqual(plan[0], { start: 1, end: 5, level: 1.8, points: [{ t: 1, x: 100, y: 100 }, { t: 4, x: 600, y: 400 }] });
  assert.equal(Math.round((plan[1].end - plan[1].start) * 1000) / 1000, 1.6, 'a 0.3s moment is stretched to ease in and out');
  assert.deepEqual(plan[1].points[0], { t: 12, x: 800, y: 0 }, 'points are clamped inside the frame');
  assert.equal(zoomPlan([{ start: 19.9, end: 25, x: 1, y: 1 }], size)[0].end, 20, 'never past the end');
});

test('too many zooms: manual moments fail clearly, auto-zoom widens the gap, pans are thinned', () => {
  const many = Array.from({ length: 30 }, (_, i) => ({ start: i * 4 + (i % 3) * 0.9, end: i * 4 + (i % 3) * 0.9 + 0.5, x: 10 * i, y: 10 }));
  const long = { ...size, duration: 130 };
  assert.throws(() => zoomPlan(many, long), e => e.code === 'INVALID_ARGUMENTS' && /limit is 20/.test(e.message));
  const fit = zoomPlan(many, { ...long, fit: true });
  assert.ok(fit.length <= 20 && fit.length > 1);
  assert.ok(fit.every(b => b.points.length <= 8));
});

test('the graph splits at exact frames and zooms only inside blocks', () => {
  const plan = zoomPlan([{ start: 2, end: 4, x: 200, y: 150 }], size);
  const g = zoomGraph(plan, size);
  assert.match(g, new RegExp(`^\\[0:v\\]fps=${FPS},split=3`));
  assert.match(g, /trim=start_frame=0:end_frame=60,setpts=PTS-STARTPTS\[p0\]/);
  assert.match(g, /trim=start_frame=60:end_frame=120,setpts=PTS-STARTPTS,perspective=/);
  assert.match(g, /trim=start_frame=120,setpts=PTS-STARTPTS\[p2\]/);
  assert.equal(zoomGraph([], size), null);
  const e = zoomExpressions(plan[0], { ...size, offset: 2 });
  assert.deepEqual(Object.keys(e), ['x0', 'y0', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3']);
  assert.ok(e.x0.length < 2000, 'expressions stay short because perspective re-reads them every frame');
});

test('rendering keeps every frame, leaves unzoomed frames alone, and zooms on the target', { skip: !has('ffmpeg') }, () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'studio-test-'));
  try {
    const src = path.join(dir, 'src.mp4'), out = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=320x240:r=30:d=4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', src]);
    const plan = zoomPlan([{ start: 1, end: 3, x: 240, y: 180, level: 2 }], { width: 320, height: 240, duration: 4 });
    execFileSync('ffmpeg', ['-loglevel', 'error', '-i', src, '-filter_complex', zoomGraph(plan, { width: 320, height: 240 }), '-map', '[out]', '-c:v', 'libx264', '-y', out]);
    const frames = execFileSync('ffprobe', ['-v', 'error', '-count_frames', '-show_entries', 'stream=nb_read_frames,width,height', '-of', 'csv=p=0', out]).toString().trim();
    assert.equal(frames, '320,240,120');
    // Mean difference from the source: ~0 before the zoom, large at its peak.
    const psnr = n => { const r = execFileSync('sh', ['-c', `ffmpeg -i "${src}" -i "${out}" -lavfi "[0:v]select=eq(n\\,${n})[a];[1:v]select=eq(n\\,${n})[b];[a][b]psnr" -f null - 2>&1`]).toString(); const v = /average:([\d.]+|inf)/.exec(r)?.[1]; return v === 'inf' ? 99 : Number(v); };
    assert.ok(psnr(10) > 35, 'frames before the zoom match the source');
    assert.ok(psnr(60) < 20, 'the zoom peak differs from the source');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('cursor recipes: named or numeric sizes, colours or false, unknown keys rejected', () => {
  assert.equal(parseCursor(undefined), null); assert.equal(parseCursor(false), null);
  assert.deepEqual(parseCursor(true), { size: SIZES.normal, smooth: 0.5, highlight: YELLOW, ripple: '#FFFFFF' });
  assert.deepEqual(parseCursor({ size: 'huge', smooth: 0, highlight: '#ff0000', ripple: false }), { size: 2.6, smooth: 0, highlight: '#FF0000', ripple: null });
  assert.equal(parseCursor({ size: '2.2' }).size, 2.2);
  assert.equal(parseRecipe({ cursor: { size: 'big' } }).cursor.size, 2);
  for (const c of [{ size: 5 }, { size: 'giant' }, { smooth: 2 }, { highlight: 'yellow' }, { trail: true }, []]) assert.throws(() => parseCursor(c), e => e.code === 'INVALID_ARGUMENTS', JSON.stringify(c));
});

test('cursor path: holds between samples, glides into the next, smoothing keeps the endpoints', () => {
  const track = { moves: [[1, 100, 100], [2, 300, 200]], cursor_in_video: true };
  const raw = cursorFrames(track, { duration: 3, smooth: 0 });
  assert.equal(raw.length, 90); assert.equal(raw[0], null, 'unknown before the first sample');
  assert.deepEqual(raw[30], [100, 100]); assert.deepEqual(raw[57], [100, 100], 'held until 50ms before the next sample');
  assert.deepEqual(raw[60], [300, 200]); assert.deepEqual(raw[89], [300, 200]);
  const hidden = cursorFrames({ ...track, cursor_in_video: false }, { duration: 3, smooth: 0 });
  assert.deepEqual(hidden[0], [100, 100], 'a drawn cursor sits at its first position from the start');
  const soft = cursorFrames(track, { duration: 3, smooth: 1 });
  assert.ok(soft[55][0] > 100 && soft[55][0] < 300, 'smoothing starts the glide early, with no lag');
  assert.ok(Math.abs(soft[89][0] - 300) < 3 && Math.abs(soft[30][0] - 100) < 3, 'settled positions stay put');
});

test('cursor commands move only on change and park off-screen while unknown', () => {
  const cmds = cursorCommands([null, [10, 20], [10, 20], [30, 40]], { halo: 100, arrow: { hot: 5 } });
  assert.equal(cmds.halo, '0.0000 overlay@halo x -9999, overlay@halo y -9999;\n0.0333 overlay@halo x -40, overlay@halo y -30;\n0.1000 overlay@halo x -20, overlay@halo y -10;\n');
  assert.match(cmds.arrow, /^0\.0333 overlay@arrow x 5, overlay@arrow y 15;$/m);
  assert.equal(cursorCommands([[1, 1]], { halo: 0, arrow: null }).arrow, null);
});

test('cursor chain: highlight and arrow each carry their own positions; ripples sit on the real click', () => {
  const opts = parseCursor({ size: 'big' });
  const c = cursorChain({ clicks: [[1.5, 200, 100, 1]], opts, arrow: { hot: 10 }, cmds: { halo: 'h.cmd', arrow: 'a.cmd' } });
  assert.equal(c.out, '[c3]'); assert.equal(c.ripples, 1);
  assert.match(c.text, /sendcmd=f='h\.cmd'\[halo\]/); assert.match(c.text, /\[1:v\]format=rgba,sendcmd=f='a\.cmd'\[arw\]/);
  assert.match(c.text, /\[r0\]setpts=PTS\+1\.5\/TB\[rs0\];\[c2\]\[rs0\]overlay=x=80:y=-20:eof_action=pass\[c3\]/);
  const many = Array.from({ length: 80 }, (_, i) => [i, 10, 10, 1]);
  const baked = cursorChain({ clicks: many, opts: parseCursor({ highlight: false }), arrow: null, cmds: {} });
  assert.equal(baked.ripples, MAX_RIPPLES); assert.doesNotMatch(baked.text, /halo|arw/);
});

test('rendering draws the cursor layers on the right frames', { skip: !has('ffmpeg') }, () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'studio-cursor-'));
  try {
    const src = path.join(dir, 'src.mp4'), out = path.join(dir, 'out.mp4'), halo = path.join(dir, 'halo.cmd');
    execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=320x240:r=30:d=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', src]);
    const opts = parseCursor({ highlight: '#FFFFFF', ripple: false });
    const frames = cursorFrames({ moves: [[0, 60, 60], [1, 260, 180]] }, { duration: 2, smooth: 0 });
    writeFileSync(halo, cursorCommands(frames, { halo: Math.round(56 * opts.size) }).halo);
    const c = cursorChain({ clicks: [], opts, arrow: null, cmds: { halo } });
    execFileSync('ffmpeg', ['-loglevel', 'error', '-i', src, '-filter_complex', `${c.text};${c.out}format=yuv420p[out]`, '-map', '[out]', '-c:v', 'libx264', '-y', out]);
    const luma = (n, x, y) => Number(execFileSync('sh', ['-c', `ffmpeg -loglevel error -i "${out}" -vf "select=eq(n\\,${n}),crop=4:4:${x - 2}:${y - 2},format=gray" -frames:v 1 -f rawvideo - | od -An -tu1 | awk '{for(i=1;i<=NF;i++)s+=$i} END{print s/16}'`]).toString());
    assert.ok(luma(10, 60, 60) > 60 && luma(10, 260, 180) < 20, 'highlight at the first position');
    assert.ok(luma(45, 260, 180) > 60 && luma(45, 60, 60) < 20, 'and at the second after the move');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('backgrounds use the image editor names and colours; custom needs a colour; unknown keys rejected', () => {
  assert.equal(parseBackground(undefined), null); assert.equal(parseBackground('none'), null); assert.equal(parseBackground({ style: 'None' }), null);
  assert.deepEqual(parseBackground(true), { style: 'ocean', colors: BACKDROPS.ocean, corner_radius: 18, padding: 0.06, shadow: 0.45 });
  assert.deepEqual(Object.keys(BACKDROPS), ['dusk', 'ocean', 'meadow', 'slate']);
  assert.equal(parseBackground('Dusk').style, 'dusk');
  const custom = parseBackground({ color: '#1e293b', corner_radius: 30 });
  assert.equal(custom.style, 'custom'); assert.deepEqual(custom.colors, ['#1E293B', '#1E293B']); assert.equal(custom.corner_radius, 30);
  assert.equal(parseRecipe({ background: 'slate' }).background.style, 'slate');
  for (const b of [{ style: 'midnight' }, { style: 'custom' }, { style: 'ocean', color: '#000000' }, { color: 'navy' }, { corner_radius: 500 }, { padding: 1 }, { blur: 3 }, []]) assert.throws(() => parseBackground(b), e => e.code === 'INVALID_ARGUMENTS', JSON.stringify(b));
});

test('background layout matches the Mac: 6% padding (at least 32px) around the full-size video', () => {
  const L = backgroundLayout(parseBackground('ocean'), { width: 1280, height: 800 });
  assert.deepEqual(L, { W: 1434, H: 954, w: 1280, h: 800, x: 77, y: 77, r: 18 });
  assert.equal(backgroundLayout(parseBackground('ocean'), { width: 320, height: 240 }).x, 32);
  assert.equal(backgroundLayout(parseBackground({ style: 'ocean', padding: 0 }), { width: 321, height: 241 }).W, 322, 'odd sizes are made even for H.264');
});

test('background render: backdrop colours outside, video untouched inside, rounded corners', { skip: !has('ffmpeg') || !has('convert') }, async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'studio-bg-'));
  try {
    const src = path.join(dir, 'src.mp4'), out = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=white:s=320x240:r=30:d=1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', src]);
    const bg = parseBackground({ color: '#FF0000', corner_radius: 20, shadow: false }), L = backgroundLayout(bg, { width: 320, height: 240 });
    const art = await drawBackground(dir, bg, L);
    execFileSync('ffmpeg', ['-loglevel', 'error', '-i', src, '-loop', '1', '-framerate', '30', '-i', art.file, '-filter_complex', backgroundChain(L, { input: '[0:v]fps=30,', bgIn: 1 }), '-map', '[out]', '-c:v', 'libx264', '-y', out]);
    const probe = execFileSync('ffprobe', ['-v', 'error', '-count_frames', '-show_entries', 'stream=nb_read_frames,width,height', '-of', 'csv=p=0', out]).toString().trim();
    assert.equal(probe, `${L.W},${L.H},30`, 'every frame kept, canvas grown by the padding');
    const px = (x, y) => execFileSync('sh', ['-c', `ffmpeg -loglevel error -i "${out}" -vf "select=eq(n\\,5),crop=2:2:${x}:${y}" -frames:v 1 -f rawvideo -pix_fmt rgb24 - | od -An -tu1`]).toString().trim().split(/\s+/).map(Number).slice(0, 3);
    const red = p => p[0] > 200 && p[1] < 60 && p[2] < 60, white = p => p.every(v => v > 220);
    assert.ok(red(px(10, 10)), 'backdrop in the padding');
    assert.ok(white(px(L.x + 160, L.y + 120)), 'video in the middle');
    assert.ok(red(px(L.x + 2, L.y + 2)), 'the corner is rounded off');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
