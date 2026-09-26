import { createHash, randomUUID } from 'node:crypto';
import { readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { ocrLines } from './desktop.mjs';
import { captureEntry } from './library.mjs';
import { atomic, directory, fail, imageCommand, pngSize, readSafe, run, statePath } from './system.mjs';

// screenshot.compare and screenshot.targets, matching the Mac app's results:
// same field names, image-pixel top-left rectangles, 32px change tiles and
// stable OCR region IDs.
const MAX_PIXELS = 32_000_000, TILE = 32;

async function rgb(file, width, height) {
  if (width * height > MAX_PIXELS) fail('TOO_LARGE', 'Comparison supports up to 32 million pixels per image.');
  // Flatten transparency onto white, as the Mac app does, then read raw RGB.
  const { stdout } = await run(await imageCommand(), [file, '-background', 'white', '-alpha', 'remove', '-alpha', 'off', '-depth', '8', 'rgb:-'], { encoding: 'buffer', maxBuffer: width * height * 3 + 1024, timeout: 60_000 });
  if (stdout.length !== width * height * 3) fail('INVALID_IMAGE', 'Cannot decode comparison pixels.');
  return stdout;
}
const inside = (r, w, h) => r[2] > 0 && r[3] > 0 && r[0] >= 0 && r[1] >= 0 && r[0] + r[2] <= w && r[1] + r[3] <= h;
const overlaps = (a, b) => a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];

export function difference(a, b, width, height, ignored, threshold) {
  const columns = Math.ceil(width / TILE), cells = new Set();
  let changed = 0, compared = 0;
  for (let y = 0; y < height; y++) {
    const spans = ignored.filter(r => y >= r[1] && y < r[1] + r[3]);
    for (let x = 0; x < width; x++) {
      if (spans.length && spans.some(r => x >= r[0] && x < r[0] + r[2])) continue;
      compared++;
      const i = (y * width + x) * 3;
      if (Math.abs(a[i] - b[i]) > threshold || Math.abs(a[i + 1] - b[i + 1]) > threshold || Math.abs(a[i + 2] - b[i + 2]) > threshold) { changed++; cells.add(Math.floor(y / TILE) * columns + Math.floor(x / TILE)); }
    }
  }
  const regions = [];
  for (const first of cells) {
    if (!cells.delete(first)) continue;
    const queue = [first]; let minX = first % columns, maxX = minX, minY = Math.floor(first / columns), maxY = minY;
    for (let q = 0; q < queue.length; q++) {
      const cell = queue[q], x = cell % columns, y = Math.floor(cell / columns);
      minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      for (const peer of [x > 0 ? cell - 1 : -1, x + 1 < columns ? cell + 1 : -1, cell - columns, cell + columns]) if (cells.delete(peer)) queue.push(peer);
    }
    const x0 = minX * TILE, y0 = minY * TILE;
    regions.push([x0, y0, Math.min((maxX + 1) * TILE, width) - x0, Math.min((maxY + 1) * TILE, height) - y0]);
  }
  regions.sort((p, q) => p[1] - q[1] || p[0] - q[0]);
  return { changed, compared, regions };
}

export function changedText(before, after, ignored) {
  const texts = lines => new Set(lines.filter(l => !ignored.some(r => overlaps(r, l.rect))).map(l => l.text.trim()).filter(Boolean));
  const a = texts(before), b = texts(after);
  return { removed: [...a].filter(t => !b.has(t)).sort(), added: [...b].filter(t => !a.has(t)).sort() };
}

async function previewPath() {
  const dir = await directory(path.join(statePath(), 'previews'), true, true);
  for (const file of await readdir(dir)) if (/^(comparison-)?[0-9a-f-]{36}\.png$/.test(file)) {
    const info = await stat(path.join(dir, file)).catch(() => null); if (info && Date.now() - info.mtimeMs > 3600_000) await rm(path.join(dir, file), { force: true });
  }
  return path.join(dir, `comparison-${randomUUID()}.png`);
}
async function render(beforeFile, afterFile, width, height, regions, ignored) {
  const scale = Math.min(1, 1400 / (width * 2)), pw = Math.max(1, Math.round(width * scale)), ph = Math.max(1, Math.round(height * scale));
  const box = r => `${Math.round(r[0] * scale)},${Math.round(r[1] * scale)} ${Math.round((r[0] + r[2]) * scale) - 1},${Math.round((r[1] + r[3]) * scale) - 1}`;
  const marks = [
    ...(regions.length ? ['-fill', 'rgba(255,59,48,0.18)', '-stroke', 'rgb(255,59,48)', '-strokewidth', '1', ...regions.slice(0, 500).flatMap(r => ['-draw', `rectangle ${box(r)}`])] : []),
    ...(ignored.length ? ['-stroke', 'none', '-fill', 'rgba(128,128,128,0.5)', ...ignored.flatMap(r => ['-draw', `rectangle ${box(r)}`])] : []),
  ];
  const panel = file => ['(', file, '-background', 'white', '-alpha', 'remove', '-alpha', 'off', '-resize', `${pw}x${ph}!`, ...marks, ')'];
  const out = await previewPath();
  // A black 32px strip under the panels matches the Mac layout; labels are left
  // to the result fields so no system font is required.
  await run(await imageCommand(), [...panel(beforeFile), ...panel(afterFile), '+append', '-background', 'black', '-gravity', 'north', '-extent', `${pw * 2}x${ph + 32}`, `PNG32:${out}`], { timeout: 60_000 });
  const data = await readSafe(out, 128 * 1024 * 1024);
  const size = pngSize(data);
  return { path: out, mime_type: 'image/png', width: size.width, height: size.height, duration: null, file_size: data.length, preview_path: out };
}

export async function compare({ before_id, after_id, ignore_rects = [], threshold = 20 }) {
  const before = await captureEntry(before_id), after = await captureEntry(after_id);
  const aSize = pngSize(await readSafe(before.image_path, 128 * 1024 * 1024)), bSize = pngSize(await readSafe(after.image_path, 128 * 1024 * 1024));
  if (aSize.width !== bSize.width || aSize.height !== bSize.height) fail('SIZE_MISMATCH', 'Screenshots must have equal pixel dimensions. Capture the same window size or crop them explicitly first.');
  const { width, height } = aSize;
  if (!Number.isFinite(threshold) || threshold < 0 || threshold > 255) fail('INVALID_ARGUMENTS', 'threshold must be 0 to 255.');
  if (ignore_rects.length > 50 || !ignore_rects.every(r => inside(r, width, height))) fail('INVALID_ARGUMENTS', 'Ignored rectangles must fit inside the source image.');
  const level = Math.trunc(threshold);
  const diff = difference(await rgb(before.image_path, width, height), await rgb(after.image_path, width, height), width, height, ignore_rects, level);
  let text = { removed: [], added: [] }, text_status = 'ready';
  try { text = changedText(await ocrLines(before.image_path), await ocrLines(after.image_path), ignore_rects); } catch (error) { if (error.code !== 'DEPENDENCY_MISSING') throw error; text_status = 'unavailable'; }
  // Refuse a result when either source changed while we were comparing.
  const [a2, b2] = [await captureEntry(before_id), await captureEntry(after_id)];
  if (a2.path !== before.path || b2.path !== after.path || a2.updated_at !== before.updated_at || b2.updated_at !== after.updated_at) fail('CONTENT_CHANGED', 'A source changed during comparison. Select the current images again.');
  const attachment = await render(before.image_path, after.image_path, width, height, diff.regions, ignore_rects);
  return {
    before_id: before.item_id, after_id: after.item_id, coordinates: 'image-pixels-top-left', changed_pixels: diff.changed, compared_pixels: diff.compared,
    change_ratio: diff.compared === 0 ? 0 : diff.changed / diff.compared, threshold: level, regions: diff.regions.slice(0, 200), total_regions: diff.regions.length,
    truncated: diff.regions.length > 200, changed_text: text, ...(text_status === 'ready' ? {} : { changed_text_status: text_status }),
    path: attachment.path, attachment, temporary: true, expires_at: new Date(Date.now() + 3600_000).toISOString(),
  };
}

// Stable IDs: the same text in the same place always gets the same ID.
const regionId = (prefix, text, rect) => `${prefix}${createHash('sha256').update(text + rect.map(v => v.toFixed(2)).join(',')).digest('hex').slice(0, 24)}`;
export function targetRegions(lines, granularity = 'line') {
  if (granularity === 'word') return lines.flatMap(l => l.words ?? []).slice(0, 2000).map(w => ({ id: regionId('word-ocr-', w.text, w.rect), text: w.text, rect: w.rect, granularity: 'word' }));
  return lines.slice(0, 2000).map(l => ({ id: regionId('ocr-', l.text, l.rect), text: l.text, rect: l.rect, granularity: 'line' }));
}
const fold = s => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
export async function targets({ id, query, granularity = 'line' }) {
  const entry = await captureEntry(id);
  const regions = targetRegions(await ocrLines(entry.image_path), granularity);
  const matches = query ? regions.filter(r => fold(r.text).includes(fold(query))) : regions;
  return { source_id: entry.item_id, coordinates: 'image-pixels-top-left', regions: matches.slice(0, 200), total: matches.length, truncated: matches.length > 200 };
}
