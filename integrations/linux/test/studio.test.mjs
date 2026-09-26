import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { FPS, LEVELS, level, parseRecipe, zoomExpressions, zoomGraph, zoomPlan } from '../studio.mjs';

const size = { width: 800, height: 600, duration: 20 };
const has = cmd => { try { execFileSync(cmd, ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } };

test('recipes are strict JSON: named or numeric levels, unknown keys rejected', () => {
  assert.equal(level('subtle'), LEVELS.subtle); assert.equal(level(undefined), LEVELS.normal); assert.equal(level('2.2'), 2.2);
  assert.deepEqual(parseRecipe({}), { zoom: null });
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
