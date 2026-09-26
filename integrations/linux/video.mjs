import { readdir, rm, stat, writeFile, mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { recordingEntry, saveRecording } from './library.mjs';
import { dependencies, directory, fail, imageCommand, pngSize, readSafe, run, statePath, unsupported } from './system.mjs';

// Frames and export for saved recordings, matching AgentVideo.swift and
// AgentVideoEdits.swift on the Mac: the source video is never changed.
const EXPIRES = 3600_000;
async function tools() {
  const deps = await dependencies();
  if (!deps.ffmpeg || !deps.ffprobe) fail('DEPENDENCY_MISSING', 'Install ffmpeg (with ffprobe) to read or export recordings.');
  return deps;
}
export async function probeVideo(file) {
  const { ffprobe } = await tools();
  const { stdout } = await run(ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height:format=duration', '-of', 'json', file]);
  const info = JSON.parse(stdout), stream = info.streams?.[0], duration = parseFloat(info.format?.duration);
  if (!stream || !Number.isFinite(duration) || duration <= 0) fail('INVALID_VIDEO', 'Recording has no playable video track.');
  return { width: stream.width, height: stream.height, duration };
}
async function previewFile(prefix) {
  const dir = await directory(path.join(statePath(), 'previews'), true, true);
  for (const file of await readdir(dir)) if (/^(frame|contact-sheet)-[0-9a-f-]{36}\.png$/.test(file)) {
    const info = await stat(path.join(dir, file)).catch(() => null); if (info && Date.now() - info.mtimeMs > EXPIRES) await rm(path.join(dir, file), { force: true });
  }
  return path.join(dir, `${prefix}-${randomUUID()}.png`);
}
async function imageResult(file) {
  const { width, height } = pngSize(await readSafe(file, 64 * 1024 * 1024));
  return { path: file, mime_type: 'image/png', width, height, temporary: true, expires_at: new Date(Date.now() + EXPIRES).toISOString() };
}

export function sampleTimes(times, count, duration) {
  if (!Number.isFinite(duration) || duration <= 0 || !Number.isInteger(count) || count < 1 || count > 12) fail('INVALID_ARGUMENTS', 'Use 1 to 12 frames from a nonempty video.');
  const list = times ?? Array.from({ length: count }, (_, i) => duration * (i + 0.5) / count);
  if (!list.length || list.length > 12 || !list.every(t => Number.isFinite(t) && t >= 0 && t < duration)) fail('INVALID_ARGUMENTS', 'Frame times must be inside the video (strictly before its end).');
  return list;
}
export async function frames({ id, times, count, width = 400 }) {
  if (times !== undefined && count !== undefined) fail('INVALID_ARGUMENTS', 'Choose times or count.');
  if (!Number.isInteger(width) || (count !== undefined && !Number.isInteger(count))) fail('INVALID_ARGUMENTS', 'Count and width must be integers.');
  const { ffmpeg } = await tools(), entry = await recordingEntry(id), { duration } = await probeVideo(entry.video_path);
  const list = sampleTimes(times, count ?? 6, duration), results = [], files = [];
  for (const time of list) {
    const file = await previewFile('frame');
    // Fit inside width x width like AVAssetImageGenerator.maximumSize.
    await run(ffmpeg, ['-nostdin', '-loglevel', 'error', '-ss', time.toFixed(3), '-i', entry.video_path, '-frames:v', '1', '-vf', `scale=w='min(iw,${width})':h='min(ih,${width})':force_original_aspect_ratio=decrease`, '-y', file]);
    const stats = await stat(file).catch(() => null);
    if (!stats?.size) fail('EXPORT_FAILED', `No frame could be read at ${time.toFixed(2)}s.`);
    files.push(file); results.push({ ...await imageResult(file), requested_time: time, actual_time: time });
  }
  // Contact sheet: up to 3 columns, each frame over a black strip labeled with its time.
  const im = await imageCommand(), sheet = await previewFile('contact-sheet'), columns = Math.min(3, files.length), rows = [];
  for (let r = 0; r < files.length; r += columns) rows.push(['(', ...files.slice(r, r + columns).flatMap((f, i) => ['(', f, '-background', 'black', '-gravity', 'north', '-splice', '0x28', '-fill', 'white', '-pointsize', '14', '-gravity', 'northwest', '-annotate', '+8+6', `${list[r + i].toFixed(2)}s`, ')']), '+append', ')']);
  await run(im, [...rows.flat(), '-background', 'black', '-append', `PNG32:${sheet}`]);
  return { id: entry.item_id, frames: results, contact_sheet: await imageResult(sheet), duration };
}

// Timed edits. Times are in SOURCE seconds; rects are source pixels top-left.
const charsPer = (width, font) => Math.max(1, Math.floor((width - 24) / (font * 0.56)));
function wrap(text, perLine) {
  const lines = [];
  for (const word of text.trim().split(/\s+/)) {
    let w = word;
    while (w.length > perLine) { lines.push(w.slice(0, perLine)); w = w.slice(perLine); }
    if (lines.length && (lines.at(-1) + ' ' + w).length <= perLine && !lines.at(-1).endsWith('\u0000')) lines[lines.length - 1] += ' ' + w; else lines.push(w);
  }
  return lines;
}
const xml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]));
export function prepareEdits(inputs = [], width, height, duration) {
  if (inputs.length > 20) fail('INVALID_ARGUMENTS', 'Use at most 20 timed edits.');
  const out = [];
  for (const e of inputs) {
    const { type, start, end, rect, text, number } = e;
    if (!['caption', 'step', 'title', 'zoom', 'redact'].includes(type) || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || start >= end || end > duration + 0.001) fail('INVALID_ARGUMENTS', 'Every edit needs a valid type and start/end inside the original recording.');
    if (rect !== undefined) {
      if (!Array.isArray(rect) || rect.length !== 4 || rect.some(n => !Number.isFinite(n)) || rect[0] < 0 || rect[1] < 0 || rect[2] < 2 || rect[3] < 2 || rect[0] + rect[2] > width || rect[1] + rect[3] > height) fail('INVALID_ARGUMENTS', 'Edit rectangles must fit the oriented source video.');
    }
    const item = { type, start, end };
    if (type === 'zoom' || type === 'redact') {
      if (!rect || text !== undefined || number !== undefined) fail('INVALID_ARGUMENTS', 'Zoom and redact require rect, without text or number.');
      if (type === 'zoom' && Math.max(width / rect[2], height / rect[3]) > 8) fail('INVALID_ARGUMENTS', 'Zoom is limited to 8×.');
      if (type === 'zoom' && out.some(o => o.type === 'zoom' && start < o.end && end > o.start)) fail('INVALID_ARGUMENTS', 'Zoom intervals cannot overlap.');
      item.rect = rect.map(Math.round);
    } else {
      if (typeof text !== 'string' || !text.trim() || [...text].length > 200 || rect !== undefined || (type !== 'step' && number !== undefined)) fail('INVALID_ARGUMENTS', 'Captions, steps and titles require text, without rect. Only steps accept number.');
      if (type === 'step' && !(Number.isInteger(number) && number >= 1 && number <= 99)) fail('INVALID_ARGUMENTS', 'Steps require an integer number from 1 to 99.');
      const label = type === 'step' ? `${number}. ${text}` : text;
      const font = Math.max(14, Math.min(type === 'title' ? 64 : 36, width / 28)), boxWidth = Math.floor(width * 0.9);
      const lines = wrap(label, charsPer(boxWidth, font)), boxHeight = Math.ceil(lines.length * font * 1.25 + 24);
      if (boxWidth < 40 || boxHeight > height * 0.6) fail('INVALID_ARGUMENTS', 'Overlay text does not fit the video; shorten it.');
      if (out.some(o => o.type === type && start < o.end && end > o.start)) fail('INVALID_ARGUMENTS', 'Overlays of the same type cannot overlap in time.');
      // Captions sit at the bottom, steps at the top, titles in the middle (as on the Mac).
      const y = type === 'title' ? Math.round((height - boxHeight) / 2) : type === 'step' ? 16 : height - boxHeight - 16;
      Object.assign(item, { lines, font, boxWidth, boxHeight, x: Math.round((width - boxWidth) / 2), y, opacity: type === 'title' ? 1 : 0.85 });
    }
    out.push(item);
  }
  return out;
}
const between = e => `enable='between(t\\,${e.start.toFixed(3)}\\,${e.end.toFixed(3)})'`;
export function filterGraph(edits, width, height, start, end, scaleTo) {
  const chain = [], overlays = edits.filter(e => e.lines);
  let cur = '[0:v]', n = 0;
  const next = () => `[v${n++}]`;
  const redacts = edits.filter(e => e.type === 'redact');
  if (redacts.length) { const o = next(); chain.push(`${cur}${redacts.map(e => `drawbox=x=${e.rect[0]}:y=${e.rect[1]}:w=${e.rect[2]}:h=${e.rect[3]}:color=black:t=fill:${between(e)}`).join(',')}${o}`); cur = o; }
  for (const e of edits.filter(e => e.type === 'zoom')) {
    const a = next(), b = next(), z = next(), o = next(), [x, y, w, h] = e.rect;
    chain.push(`${cur}split${a}${b}`, `${b}crop=${w}:${h}:${x}:${y},scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1${z}`, `${a}${z}overlay=0:0:${between(e)}${o}`);
    cur = o;
  }
  overlays.forEach((e, i) => { const o = next(); chain.push(`${cur}[${i + 1}:v]overlay=${e.x}:${e.y}:${between(e)}${o}`); cur = o; });
  const scale = scaleTo ? `,scale=w='min(iw,${scaleTo[0]})':h='min(ih,${scaleTo[1]})':force_original_aspect_ratio=decrease:force_divisible_by=2` : '';
  chain.push(`${cur}trim=start=${start.toFixed(3)}:end=${end.toFixed(3)},setpts=PTS-STARTPTS${scale},format=yuv420p[out]`);
  return chain.join(';');
}
async function renderOverlay(e, work, index) {
  const svg = path.join(work, `overlay-${index}.svg`), png = path.join(work, `overlay-${index}.png`);
  const rows = e.lines.map((line, i) => `<text x="${e.boxWidth / 2}" y="${12 + e.font * (i + 1) * 1.25 - e.font * 0.25}" text-anchor="middle" font-family="DejaVu Sans" font-weight="bold" font-size="${e.font}" fill="white">${xml(line)}</text>`).join('');
  await writeFile(svg, `<svg xmlns="http://www.w3.org/2000/svg" width="${e.boxWidth}" height="${e.boxHeight}"><rect width="100%" height="100%" fill="black" fill-opacity="${e.opacity}"/>${rows}</svg>`, { mode: 0o600 });
  await run(await imageCommand(), ['-background', 'none', `MSVG:${svg}`, `PNG32:${png}`]);
  return png;
}
export async function exportClip({ id, start = 0, end, max_bytes, edits = [], lease_id }) {
  if (lease_id) unsupported('Leases are not supported on Linux.');
  const { ffmpeg } = await tools(), entry = await recordingEntry(id), source = await probeVideo(entry.video_path);
  const finish = end ?? source.duration;
  if (!Number.isFinite(start) || !Number.isFinite(finish) || start < 0 || finish <= start || finish > source.duration + 0.001) fail('INVALID_ARGUMENTS', 'Trim bounds must be inside the video, with end after start.');
  const prepared = prepareEdits(edits, source.width, source.height, source.duration);
  const work = await mkdtemp(path.join(os.tmpdir(), 'myman-export-'));
  try {
    const overlayFiles = [];
    for (const [i, e] of prepared.filter(e => e.lines).entries()) overlayFiles.push(await renderOverlay(e, work, i));
    const out = path.join(work, 'export.mp4');
    // Full quality first; a byte cap may lower resolution, never truncate duration.
    const tiers = max_bytes === undefined ? [null] : [null, [1280, 720], [640, 480]];
    for (const tier of tiers) {
      await run(ffmpeg, ['-nostdin', '-loglevel', 'error', '-i', entry.video_path, ...overlayFiles.flatMap(f => ['-i', f]), '-filter_complex', filterGraph(prepared, source.width, source.height, start, Math.min(finish, source.duration), tier), '-map', '[out]', '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', tier ? '26' : '20', '-movflags', '+faststart', '-y', out], { timeout: 15 * 60_000 });
      const size = (await stat(out)).size;
      if (max_bytes === undefined || size <= max_bytes) {
        const info = await probeVideo(out);
        const result = await saveRecording({ file: out, width: info.width, height: info.height, duration: info.duration, started_at: entry.captured_local ?? entry.timestamp, backend: 'ffmpeg export', source_id: entry.item_id });
        return { ...result, source_id: entry.item_id, trim: { start, end: Math.min(finish, source.duration) }, edits: prepared.map(e => e.type) };
      }
    }
    fail('SIZE_LIMIT_EXCEEDED', 'The complete clip cannot fit at supported quality. Increase max_bytes or shorten the trim range.');
  } finally { await rm(work, { recursive: true, force: true }); }
}
