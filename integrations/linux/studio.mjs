import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { recordingEntry, saveRecording } from './library.mjs';
import { probeVideo } from './video.mjs';
import { dependencies, fail, imageCommand, readSafe, rootPath, run } from './system.mjs';

// myman record polish: a finished recording plus a small JSON recipe becomes a
// polished copy (the source is never changed). Step one is smooth auto-zoom:
// ease in on the moments the cursor track flagged, pan between nearby moments,
// ease back out. Every choice is plain JSON so an agent can read the plan
// (--dry-run), edit it, and render the same result again.
export const LEVELS = { subtle: 1.4, normal: 1.8, strong: 2.4 };
export const FPS = 30;
const RECIPE_KEYS = ['zoom', 'cursor'], CURSOR_KEYS = ['size', 'smooth', 'highlight', 'ripple'], ZOOM_KEYS = ['auto', 'level', 'ramp', 'gap', 'moments'], MOMENT_KEYS = ['start', 'end', 'x', 'y', 'level'];
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
  const cursor = parseCursor(recipe.cursor);
  if (recipe.zoom === undefined) return { zoom: null, cursor };
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
  return { zoom, cursor };
}
export const SIZES = { normal: 1.5, big: 2, huge: 2.6 };
export const YELLOW = '#FFD60A';
function color(v, name, fallback) {
  if (v === undefined || v === true) return fallback;
  if (v === false) return null;
  if (typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v)) return v.toUpperCase();
  fail('INVALID_ARGUMENTS', `${name} must be true, false or a colour like "#FFD60A".`);
}
export function cursorSize(v) {
  if (v === undefined || v === true) return SIZES.normal;
  if (typeof v === 'string' && SIZES[v]) return SIZES[v];
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) v = Number(v);
  return num(v, 1, 3, 'Cursor size (or use normal, big, huge)');
}
// Cursor polish: a drawn arrow (only when the recording hid the real cursor),
// a soft highlight that follows the pointer, and a ripple on each click.
export function parseCursor(c) {
  if (c === undefined || c === false) return null;
  if (c === true) c = {};
  onlyKeys(c, CURSOR_KEYS, 'recipe.cursor');
  return { size: cursorSize(c.size), smooth: c.smooth === undefined ? 0.5 : num(c.smooth, 0, 1, 'recipe.cursor.smooth'), highlight: color(c.highlight, 'recipe.cursor.highlight', YELLOW), ripple: color(c.ripple, 'recipe.cursor.ripple', '#FFFFFF') };
}
// Where the pointer is on every output frame: linear between samples, then a
// zero-phase low-pass (forward and backward) so drawn motion glides without
// lagging behind clicks. smooth 0 keeps the raw path.
export function cursorFrames(track, { duration, smooth = 0.5 }) {
  const moves = track.moves || [], n = Math.max(1, Math.round(duration * FPS)), out = new Array(n).fill(null);
  if (!moves.length) return out;
  let j = 0;
  for (let i = 0; i < n; i++) {
    const t = i / FPS;
    if (t < moves[0][0]) continue;
    while (j + 1 < moves.length && moves[j + 1][0] <= t) j++;
    const a = moves[j], b = moves[j + 1];
    // Samples are logged only on change, so hold still until 50ms before the next one.
    if (!b || t < b[0] - 1 / 20) { out[i] = [a[1], a[2]]; continue; }
    const u = (t - (b[0] - 1 / 20)) / (1 / 20);
    out[i] = [a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u];
  }
  const first = out.findIndex(Boolean);
  if (first > 0 && track.cursor_in_video === false) for (let i = 0; i < first; i++) out[i] = out[first];
  const tau = 0.2 * smooth;
  if (tau > 0) {
    const k = 1 - Math.exp(-1 / FPS / tau);
    for (const dir of [1, -1]) {
      let prev = null;
      for (let s = dir > 0 ? 0 : n - 1; dir > 0 ? s < n : s >= 0; s += dir) {
        if (!out[s]) { prev = null; continue; }
        prev = prev ? [prev[0] + (out[s][0] - prev[0]) * k, prev[1] + (out[s][1] - prev[1]) * k] : out[s].slice();
        out[s] = prev;
      }
    }
  }
  return out.map(p => p && [Math.round(p[0] * 10) / 10, Math.round(p[1] * 10) / 10]);
}
// sendcmd script moving the highlight and arrow overlays; a line only when
// the position changes, and parked off-screen while the pointer is unknown.
export function cursorCommands(frames, { arrow, halo }) {
  const script = (name, size, off) => {
    const lines = []; let last = '';
    frames.forEach((p, i) => {
      const line = `overlay@${name} x ${p ? Math.round(p[0] - off) : -9999}, overlay@${name} y ${p ? Math.round(p[1] - off) : -9999}`;
      if (line !== last) { lines.push(`${(i / FPS).toFixed(4)} ${line};`); last = line; }
    });
    return size ? lines.join('\n') + '\n' : null;
  };
  return { halo: script('halo', halo, halo / 2), arrow: arrow ? script('arrow', 1, arrow.hot) : null };
}
const rgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
export const MAX_RIPPLES = 60;
// The cursor layers as filter text. Inputs: [0:v] video, [1:v] arrow PNG when drawn.
export function cursorChain({ clicks, opts, arrow, cmds }) {
  // Positions ride on each layer's own input via sendcmd. The overlay pulls a
  // layer frame only when it draws that moment, so a move lands on exactly its
  // frame even when later filters (the zoom's split) make ffmpeg read ahead.
  const halo = opts.highlight ? Math.round(56 * opts.size) : 0, parts = [`[0:v]fps=${FPS}[c0]`]; let at = 0;
  if (halo) {
    const [r, g, b] = rgb(opts.highlight), R = halo / 2;
    parts.push(`color=c=black@0:s=${halo}x${halo}:r=${FPS},format=rgba,geq=r=${r}:g=${g}:b=${b}:a='110*pow(max(0\\,1-hypot(X-${R}\\,Y-${R})/${R})\\,0.8)',sendcmd=f='${cmds.halo}'[halo]`);
    parts.push(`[c${at}][halo]overlay@halo=x=-9999:y=-9999:shortest=1[c${at + 1}]`); at++;
  }
  if (arrow) { parts.push(`[1:v]format=rgba,sendcmd=f='${cmds.arrow}'[arw]`, `[c${at}][arw]overlay@arrow=x=-9999:y=-9999:shortest=1[c${at + 1}]`); at++; }
  const rip = opts.ripple ? clicks.slice(0, MAX_RIPPLES) : [];
  if (rip.length) {
    const D = Math.round(120 * opts.size), R = D / 2, [r, g, b] = rgb(opts.ripple), w = Math.max(2, Math.round(2.5 * opts.size));
    parts.push(`color=c=black@0:s=${D}x${D}:r=${FPS}:d=0.45,format=rgba,geq=r=${r}:g=${g}:b=${b}:a='230*(1-T/0.45)*lte(abs(hypot(X-${R}\\,Y-${R})-(${f(R * 0.15)}+${f(R * 0.8)}*T/0.45))\\,${w})'${rip.length > 1 ? `,split=${rip.length}${rip.map((_, i) => `[r${i}]`).join('')}` : '[r0]'}`);
    rip.forEach(([t, x, y], i) => {
      // Ripples mark where the click really landed; smoothing never moves them.
      parts.push(`[r${i}]setpts=PTS+${f(t)}/TB[rs${i}]`, `[c${at}][rs${i}]overlay=x=${Math.round(x - R)}:y=${Math.round(y - R)}:eof_action=pass[c${at + 1}]`); at++;
    });
  }
  return { text: parts.join(';'), out: `[c${at}]`, ripples: rip.length };
}
// A white arrow with a dark outline and soft shadow, tip at (hot, hot).
export async function drawArrow(dir, size) {
  const s = size * 1.25, hot = Math.round(4 * s), pts = [[0, 0], [0, 17], [4.2, 13.2], [7, 19.6], [9.8, 18.4], [7.1, 12.1], [12.6, 12.1]];
  const poly = (dx, dy) => pts.map(([x, y]) => `${f(hot + x * s + dx)},${f(hot + y * s + dy)}`).join(' ');
  const W = Math.ceil(hot * 2 + 13 * s), H = Math.ceil(hot * 2 + 20 * s);
  const svg = path.join(dir, 'arrow.svg'), png = path.join(dir, 'arrow.png');
  await writeFile(svg, `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><polygon points="${poly(1.2 * s, 1.6 * s)}" fill="black" fill-opacity="0.28"/><polygon points="${poly(0, 0)}" fill="white" stroke="black" stroke-width="${f(1.1 * s)}" stroke-linejoin="round"/></svg>`, { mode: 0o600 });
  await run(await imageCommand(), ['-background', 'none', `MSVG:${svg}`, `PNG32:${png}`]);
  return { file: png, hot };
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
export function zoomGraph(plan, size, head = `[0:v]fps=${FPS}`) {
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
  return `${head}${head.endsWith(']') ? '' : ','}split=${segs.length}${segs.map((_, i) => `[s${i}]`).join('')};${parts.join(';')};${segs.map((_, i) => `[p${i}]`).join('')}concat=n=${segs.length}:v=1:a=0,format=yuv420p[out]`;
}
async function cursorTrack(entry) {
  const root = rootPath();
  if (!entry.cursor_path || !entry.cursor_path.startsWith(`${root}/assets/recording-cursor/`)) return null;
  return JSON.parse((await readSafe(entry.cursor_path, 32 * 1024 * 1024)).toString());
}
export async function polish({ id, recipe = {}, dryRun = false }) {
  const parsed = parseRecipe(recipe);
  const deps = await dependencies();
  if (!deps.ffmpeg || !deps.ffprobe) fail('DEPENDENCY_MISSING', 'Install ffmpeg (with ffprobe) to polish recordings.');
  const entry = await recordingEntry(id), source = await probeVideo(entry.video_path), track = await cursorTrack(entry);
  const warnings = [];
  // A recording made with --hide-cursor has no cursor in the picture, so it always gets one drawn.
  const hidden = track?.cursor_in_video === false;
  if (hidden && !parsed.cursor) { parsed.cursor = parseCursor(true); warnings.push('This recording hid the real cursor, so a drawn cursor was added. Pass "cursor" in the recipe to change it.'); }
  if (!parsed.zoom && !parsed.cursor) fail('INVALID_ARGUMENTS', 'Nothing to do. Pass --auto-zoom, --cursor, or a recipe such as {"zoom":{"auto":true},"cursor":{"size":"big"}}.');
  if (parsed.cursor && !track) fail('NOT_FOUND', 'This recording has no cursor track, so there is no pointer to highlight. Record again with a current MyMan.');
  if (parsed.cursor && track.pointer === 'unavailable') fail('UNSUPPORTED_DESKTOP', 'The cursor track has no pointer positions on this desktop (Sway does not expose the pointer).');
  const sx = track ? source.width / (track.width || source.width) : 1, sy = track ? source.height / (track.height || source.height) : 1;
  let plan = [], from = null;
  if (parsed.zoom) {
    let moments = parsed.zoom.moments; from = 'recipe';
    if (!moments) {
      if (!track) fail('NOT_FOUND', 'This recording has no cursor track, so auto-zoom has nothing to follow. Pass recipe.zoom.moments with start, end, x, y instead.');
      // Track positions are relative to the recorded region, which is the video.
      moments = (track.activity || []).map(a => ({ start: a.start, end: a.end, x: a.x * sx, y: a.y * sy })); from = 'cursor track';
    }
    plan = zoomPlan(moments, { ...source, level: parsed.zoom.level, ramp: parsed.zoom.ramp, gap: parsed.zoom.gap, fit: from === 'cursor track' });
  }
  const c = parsed.cursor, clicks = c ? (track.clicks || []).map(([t, x, y]) => [t, x * sx, y * sy]) : [];
  if (c && !hidden) {
    if (recipe.cursor?.size !== undefined || recipe.cursor?.smooth !== undefined) warnings.push('size and smooth need a recording made with record start --hide-cursor; the real cursor is in this video, so only the highlight and ripples were added around it.');
    c.smooth = 0; // follow the real cursor exactly
  }
  if (c?.ripple && !track.clicks_tracked) warnings.push('Clicks were not detected on this desktop, so there are no click ripples.');
  if (c?.ripple && clicks.length > MAX_RIPPLES) warnings.push(`Only the first ${MAX_RIPPLES} clicks get ripples.`);
  const recipeOut = {
    ...(parsed.zoom ? { zoom: { level: parsed.zoom.level, ramp: parsed.zoom.ramp, gap: parsed.zoom.gap, moments: plan.flatMap(b => b.points.map((p, i) => ({ start: i ? p.t : b.start, end: b.points[i + 1]?.t ?? b.end, x: p.x, y: p.y, level: b.level }))) } } : {}),
    ...(c ? { cursor: { ...(hidden ? { size: c.size, smooth: c.smooth } : {}), highlight: c.highlight ?? false, ripple: c.ripple ?? false } } : {}),
  };
  const summary = { ...(parsed.zoom ? { zooms: plan.length, moments_from: from } : {}), ...(c ? { cursor: { drawn: hidden, highlight: !!c.highlight, ripples: c.ripple ? Math.min(clicks.length, MAX_RIPPLES) : 0 } } : {}), preview_times: plan.length ? plan.map(b => Math.round(((b.start + b.end) / 2) * 100) / 100) : (clicks.length ? clicks.slice(0, 6).map(k => Math.round((k[0] + 0.15) * 100) / 100) : [Math.round(source.duration * 50) / 100]), ...(warnings.length ? { warnings } : {}) };
  if (dryRun) return { ok: true, dry_run: true, source_id: entry.item_id, width: source.width, height: source.height, duration: source.duration, plan, recipe: recipeOut, ...summary, note: 'Edit the recipe and pass it back with --recipe to adjust.' };
  if (parsed.zoom && !plan.length && !c) fail('INVALID_ARGUMENTS', 'No moments to zoom on (the cursor track found no clicks, typing or pauses). Pass recipe.zoom.moments instead.');
  const work = await mkdtemp(path.join(os.tmpdir(), 'myman-polish-'));
  try {
    const out = path.join(work, 'polished.mp4'), inputs = ['-i', entry.video_path];
    let graph;
    if (c) {
      const arrow = hidden ? await drawArrow(work, c.size) : null;
      if (arrow) inputs.push('-loop', '1', '-framerate', String(FPS), '-i', arrow.file);
      const frames = cursorFrames({ ...track, moves: (track.moves || []).map(([t, x, y]) => [t, x * sx, y * sy]) }, { duration: source.duration, smooth: c.smooth });
      const scripts = cursorCommands(frames, { arrow, halo: c.highlight ? Math.round(56 * c.size) : 0 }), cmds = {};
      for (const [k, text] of Object.entries(scripts)) if (text) { cmds[k] = path.join(work, `${k}.cmd`); await writeFile(cmds[k], text, { mode: 0o600 }); }
      const chain = cursorChain({ clicks, opts: c, arrow, cmds });
      graph = `${chain.text};${plan.length ? zoomGraph(plan, { ...source, ramp: parsed.zoom.ramp }, chain.out) : `${chain.out}format=yuv420p[out]`}`;
    } else graph = zoomGraph(plan, { ...source, ramp: parsed.zoom.ramp });
    await run(deps.ffmpeg, ['-nostdin', '-loglevel', 'error', ...inputs, '-filter_complex', graph, '-map', '[out]', '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-movflags', '+faststart', '-y', out], { timeout: 30 * 60_000 });
    await stat(out);
    const info = await probeVideo(out);
    const result = await saveRecording({ file: out, width: info.width, height: info.height, duration: info.duration, started_at: entry.captured_local ?? entry.timestamp, backend: 'myman polish', source_id: entry.item_id });
    return { ...result, source_id: entry.item_id, plan, recipe: recipeOut, ...summary, note: `Check it with myman record frames --id ${result.id} --times ${summary.preview_times.join(',')} --json.` };
  } finally { await rm(work, { recursive: true, force: true }); }
}
