import { mkdtemp, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { recordingEntry, saveRecording } from './library.mjs';
import { probeVideo } from './video.mjs';
import { dependencies, fail, readSafe, rootPath, run } from './system.mjs';

// myman record polish: a finished recording plus a small JSON recipe becomes a
// polished copy (the source is never changed). Step one is smooth auto-zoom:
// ease in on the moments the cursor track flagged, pan between nearby moments,
// ease back out. Every choice is plain JSON so an agent can read the plan
// (--dry-run), edit it, and render the same result again.
export const LEVELS = { subtle: 1.4, normal: 1.8, strong: 2.4 };
export const FPS = 30;
const RECIPE_KEYS = ['zoom'], ZOOM_KEYS = ['auto', 'level', 'ramp', 'gap', 'moments'], MOMENT_KEYS = ['start', 'end', 'x', 'y', 'level'];
const MAX_BLOCKS = 20, MAX_POINTS = 8;

function num(v, lo, hi, name) {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) fail('INVALID_ARGUMENTS', `${name} must be a number from ${lo} to ${hi}.`);
  return v;
}
function onlyKeys(obj, keys, where) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) fail('INVALID_ARGUMENTS', `${where} must be a JSON object.`);
  const extra = Object.keys(obj).filter(k => !keys.includes(k));
  if (extra.length) fail('INVALID_ARGUMENTS', `${where} has unknown key ${extra[0]}. Allowed: ${keys.join(', ')}.`);
}
export function level(v) {
  if (v === undefined || v === true) return LEVELS.normal;
  if (typeof v === 'string' && LEVELS[v]) return LEVELS[v];
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) v = Number(v);
  return num(v, 1.1, 4, 'Zoom level (or use subtle, normal, strong)');
}
// Validate a recipe and fill defaults. Unknown keys are errors, never ignored.
export function parseRecipe(recipe = {}) {
  onlyKeys(recipe, RECIPE_KEYS, 'The recipe');
  if (recipe.zoom === undefined) return { zoom: null };
  onlyKeys(recipe.zoom, ZOOM_KEYS, 'recipe.zoom');
  const z = recipe.zoom;
  const zoom = { auto: z.auto !== false && !z.moments, level: level(z.level), ramp: z.ramp === undefined ? 0.6 : num(z.ramp, 0.2, 2, 'recipe.zoom.ramp'), gap: z.gap === undefined ? 2.5 : num(z.gap, 0, 10, 'recipe.zoom.gap') };
  if (z.moments !== undefined) {
    if (!Array.isArray(z.moments) || z.moments.length > 40) fail('INVALID_ARGUMENTS', 'recipe.zoom.moments must be a list of at most 40 moments.');
    zoom.moments = z.moments.map((m, i) => {
      onlyKeys(m, MOMENT_KEYS, `recipe.zoom.moments[${i}]`);
      const start = num(m.start, 0, 86400, `moments[${i}].start`), end = num(m.end, 0, 86400, `moments[${i}].end`);
      if (end <= start) fail('INVALID_ARGUMENTS', `moments[${i}] must end after it starts.`);
      return { start, end, x: num(m.x, 0, 16000, `moments[${i}].x`), y: num(m.y, 0, 16000, `moments[${i}].y`), ...(m.level !== undefined ? { level: level(m.level) } : {}) };
    });
  }
  return { zoom };
}
// Group moments into zoom blocks. Moments closer than `gap` seconds share a
// block, so the camera pans between them instead of zooming out and back in.
export function zoomPlan(moments, { width, height, duration, level: lvl = LEVELS.normal, ramp = 0.6, gap = 2.5, fit = false }) {
  const spans = moments.map(m => ({ ...m, x: Math.min(Math.max(m.x, 0), width), y: Math.min(Math.max(m.y, 0), height), start: Math.max(0, m.start), end: Math.min(duration, m.end) }))
    .filter(m => m.end > m.start).sort((a, b) => a.start - b.start);
  const blocks = [];
  for (const s of spans) {
    const last = blocks.at(-1);
    if (last && s.start - last.end < gap) { last.end = Math.max(last.end, s.end); last.points.push({ t: s.start, x: s.x, y: s.y }); if (s.level) last.level = Math.max(last.level, s.level); }
    else blocks.push({ start: s.start, end: s.end, level: s.level ?? lvl, points: [{ t: s.start, x: s.x, y: s.y }] });
  }
  const min = 2 * ramp + 0.4;
  for (const b of blocks) if (b.end - b.start < min) { b.end = Math.min(duration, b.start + min); b.start = Math.max(0, b.end - min); }
  // Extending short blocks can make neighbours touch; merge those too.
  const merged = [];
  for (const b of blocks) { const last = merged.at(-1); if (last && b.start < last.end + 0.1) { last.end = Math.max(last.end, b.end); last.level = Math.max(last.level, b.level); last.points.push(...b.points); } else merged.push(b); }
  // Auto-zoom on a busy recording joins the two closest zooms, one pair at a
  // time, until it fits; manual moments fail instead so nothing is silently changed.
  while (fit && merged.length > MAX_BLOCKS) {
    let best = 0;
    for (let i = 1; i < merged.length - 1; i++) if (merged[i + 1].start - merged[i].end < merged[best + 1].start - merged[best].end) best = i;
    const [a, b] = merged.splice(best, 2);
    merged.splice(best, 0, { start: a.start, end: b.end, level: Math.max(a.level, b.level), points: [...a.points, ...b.points] });
  }
  if (merged.length > MAX_BLOCKS) fail('INVALID_ARGUMENTS', `That makes ${merged.length} zooms; the limit is ${MAX_BLOCKS}. Raise recipe.zoom.gap or pass fewer moments.`);
  const r = v => Math.round(v * 1000) / 1000;
  // A block pans to at most MAX_POINTS spots (evenly chosen), which keeps the
  // camera calm and the ffmpeg expressions short.
  const thin = pts => pts.length <= MAX_POINTS ? pts : Array.from({ length: MAX_POINTS }, (_, i) => pts[Math.round(i * (pts.length - 1) / (MAX_POINTS - 1))]);
  return merged.map(b => ({ start: r(b.start), end: r(b.end), level: r(b.level), points: thin(b.points).map(p => ({ t: r(p.t), x: Math.round(p.x), y: Math.round(p.y) })) }));
}
// ffmpeg expressions for the four source corners of the visible window during
// one zoom block. The perspective filter samples them with sub-pixel
// precision, so motion is smooth instead of stepping a pixel at a time.
// `offset` is the block's start in the source, because each block is rendered
// as its own trimmed segment where the frame counter starts at zero.
const f = v => (Math.round(v * 1000) / 1000).toString();
export function zoomExpressions(block, { width: W, height: H, ramp = 0.6, offset = 0 }) {
  const T = `(in/${FPS}+${f(offset)})`;
  const smooth = (a, r) => { const u = `clip((${T}-${f(a)})/${f(r)}\\,0\\,1)`; return `(${u}*${u}*(3-2*${u}))`; };
  const rin = Math.min(ramp, (block.end - block.start) / 2);
  const env = `${smooth(block.start, rin)}*(1-${smooth(block.end - rin, rin)})`;
  const path = (key, mid) => {
    let e = f(block.points[0][key]);
    for (let k = 1; k < block.points.length; k++) {
      const prev = block.points[k - 1], cur = block.points[k], pan = Math.max(0.2, Math.min(0.8, cur.t - prev.t));
      e += `+${f(cur[key] - prev[key])}*${smooth(cur.t - pan / 2, pan)}`;
    }
    return `(${f(mid)}+ld(3)*((${e})-${f(mid)}))`;
  };
  // perspective re-reads each expression every frame, so they stay short:
  // st()/ld() compute the envelope, zoom and centre once per corner.
  const pre = `st(3\\,${env})+st(0\\,1+${f(block.level - 1)}*ld(3))+st(1\\,${path('x', W / 2)})+st(2\\,${path('y', H / 2)})`;
  const x = `clip(ld(1)-${f(W / 2)}/ld(0)\\,0\\,${f(W)}-${f(W)}/ld(0))`, y = `clip(ld(2)-${f(H / 2)}/ld(0)\\,0\\,${f(H)}-${f(H)}/ld(0))`;
  const wrap = e => `0*(${pre})+${e}`;
  const xr = `(${x}+${f(W)}/ld(0))`, yb = `(${y}+${f(H)}/ld(0))`;
  return { x0: wrap(x), y0: wrap(y), x1: wrap(xr), y1: wrap(y), x2: wrap(x), y2: wrap(yb), x3: wrap(xr), y3: wrap(yb) };
}
// The whole graph: split the video at block edges (exact frames after fps),
// run perspective only on zoom blocks, pass the rest through, and concat.
export function zoomGraph(plan, size) {
  if (!plan.length) return null;
  const segs = []; let at = 0;
  for (const b of plan) {
    const s = Math.round(b.start * FPS), e = Math.round(b.end * FPS);
    if (s > at) segs.push({ from: at, to: s });
    segs.push({ from: s, to: e, block: b }); at = e;
  }
  segs.push({ from: at });
  const parts = segs.map((g, i) => {
    const trim = `trim=start_frame=${g.from}${g.to !== undefined ? `:end_frame=${g.to}` : ''},setpts=PTS-STARTPTS`;
    const persp = g.block ? `,perspective=${Object.entries(zoomExpressions(g.block, { ...size, offset: g.from / FPS })).map(([k, v]) => `${k}='${v}'`).join(':')}:interpolation=cubic:eval=frame` : '';
    return `[s${i}]${trim}${persp}[p${i}]`;
  });
  return `[0:v]fps=${FPS},split=${segs.length}${segs.map((_, i) => `[s${i}]`).join('')};${parts.join(';')};${segs.map((_, i) => `[p${i}]`).join('')}concat=n=${segs.length}:v=1:a=0,format=yuv420p[out]`;
}
async function cursorTrack(entry) {
  const root = rootPath();
  if (!entry.cursor_path || !entry.cursor_path.startsWith(`${root}/assets/recording-cursor/`)) return null;
  return JSON.parse((await readSafe(entry.cursor_path, 32 * 1024 * 1024)).toString());
}
export async function polish({ id, recipe = {}, dryRun = false }) {
  const parsed = parseRecipe(recipe);
  if (!parsed.zoom) fail('INVALID_ARGUMENTS', 'Nothing to do. Pass --auto-zoom or a recipe such as {"zoom":{"auto":true,"level":"normal"}}.');
  const deps = await dependencies();
  if (!deps.ffmpeg || !deps.ffprobe) fail('DEPENDENCY_MISSING', 'Install ffmpeg (with ffprobe) to polish recordings.');
  const entry = await recordingEntry(id), source = await probeVideo(entry.video_path);
  let moments = parsed.zoom.moments, from = 'recipe';
  if (!moments) {
    const track = await cursorTrack(entry);
    if (!track) fail('NOT_FOUND', 'This recording has no cursor track, so auto-zoom has nothing to follow. Pass recipe.zoom.moments with start, end, x, y instead.');
    // Track positions are relative to the recorded region, which is the video.
    const sx = source.width / (track.width || source.width), sy = source.height / (track.height || source.height);
    moments = (track.activity || []).map(a => ({ start: a.start, end: a.end, x: a.x * sx, y: a.y * sy })); from = 'cursor track';
  }
  const plan = zoomPlan(moments, { ...source, level: parsed.zoom.level, ramp: parsed.zoom.ramp, gap: parsed.zoom.gap, fit: from === 'cursor track' });
  const recipeOut = { zoom: { level: parsed.zoom.level, ramp: parsed.zoom.ramp, gap: parsed.zoom.gap, moments: plan.flatMap(b => b.points.map((p, i) => ({ start: i ? p.t : b.start, end: b.points[i + 1]?.t ?? b.end, x: p.x, y: p.y, level: b.level }))) } };
  const summary = { zooms: plan.length, moments_from: from, preview_times: plan.map(b => Math.round(((b.start + b.end) / 2) * 100) / 100) };
  if (dryRun) return { ok: true, dry_run: true, source_id: entry.item_id, width: source.width, height: source.height, duration: source.duration, plan, recipe: recipeOut, ...summary, note: plan.length ? 'Edit recipe.zoom.moments and pass it back with --recipe to adjust.' : 'No moments to zoom on; the copy would match the source.' };
  if (!plan.length) fail('INVALID_ARGUMENTS', 'No moments to zoom on (the cursor track found no clicks, typing or pauses). Pass recipe.zoom.moments instead.');
  const work = await mkdtemp(path.join(os.tmpdir(), 'myman-polish-'));
  try {
    const out = path.join(work, 'polished.mp4');
    await run(deps.ffmpeg, ['-nostdin', '-loglevel', 'error', '-i', entry.video_path, '-filter_complex', zoomGraph(plan, { ...source, ramp: parsed.zoom.ramp }), '-map', '[out]', '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-movflags', '+faststart', '-y', out], { timeout: 30 * 60_000 });
    await stat(out);
    const info = await probeVideo(out);
    const result = await saveRecording({ file: out, width: info.width, height: info.height, duration: info.duration, started_at: entry.captured_local ?? entry.timestamp, backend: 'myman polish', source_id: entry.item_id });
    return { ...result, source_id: entry.item_id, plan, recipe: recipeOut, ...summary, note: `Check it with myman record frames --id ${result.id ?? 'NEW-ID'} --times ${summary.preview_times.join(',')} --json.` };
  } finally { await rm(work, { recursive: true, force: true }); }
}
