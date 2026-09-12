import { BASIC_LATIN, type GlyphCandidate, type VectorGlyph, type FontMetrics } from './engine/types';
import { inkBounds, normalizeRaster } from './engine/raster';
import { estimateMetrics } from './engine/metrics';
import { rankSamples } from './engine/samples';
import { vectorizeCandidate } from './engine/vectorize';
import { loadBaseFonts, rankBaseFonts, pickBaseFont } from './engine/basefont';
import { buildFont } from './engine/font';
import { inferMissing } from './engine/inference';
import { measureStyle } from './engine/style';
import { parsePath } from './engine/paths';

type Source = { id: string; title: string; url: string; width: number; height: number; image?: HTMLImageElement };
type Sample = GlyphCandidate & { preferred?: boolean };
type Rect = { x: number; y: number; w: number; h: number };
type Character = { char: string; bbox: Rect; confidence: number; lineId: string };
type SavedSample = Omit<Sample, 'bitmap'> & { png: string };
type SavedState = { version: 1; name: string; samples: SavedSample[]; excluded: string[]; replacements: string[]; mode: string; preview: string };
declare global { interface Window {
  webkit: { messageHandlers: { font: { postMessage(value: unknown): Promise<unknown> } } };
  fontWorkbench: { start: (payload: { images: Source[]; palette?: Record<string, string>; project?: SavedState }) => Promise<void>; inspect: () => unknown; run: (capturedOnly?: boolean) => Promise<void>; exportProject: () => Promise<unknown> };
  FontEngine: { inferMissing: typeof inferMissing; measureStyle: typeof measureStyle; buildFont: typeof buildFont; parsePath: typeof parsePath };
} }
const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const bridge = <T>(action: string, values: Record<string, unknown> = {}) => window.webkit.messageHandlers.font.postMessage({ action, ...values }) as Promise<T>;
const nextFrame = () => new Promise(resolve => setTimeout(resolve, 0));
let images: Source[] = [], selected = 0, selection: Rect | null = null, drag: { x: number; y: number } | null = null;
let samples: Sample[] = [], captured: Record<string, VectorGlyph> = {}, inferred: Record<string, VectorGlyph> = {}, fallback: Record<string, VectorGlyph> = {};
let metrics: FontMetrics | null = null, estimatedSpace: VectorGlyph | null = null, generation = 0, busy = false;
let output: { bytes: ArrayBuffer; name: string; family: string; revision: number } | null = null;
let face: FontFace | null = null, matchingFaces: FontFace[] = [], excluded = new Set<string>(), replacements = new Set<string>();
let candidates: { name: string; distance: number; compared: number }[] = [], catalogSize = 0;
let mode = 'completed', timer: ReturnType<typeof setTimeout> | undefined;
const canvas = el<HTMLCanvasElement>('source'), nameInput = el<HTMLInputElement>('name');
const cleanName = () => nameInput.value.trim().slice(0, 64) || 'Screenshot Font';
function message(text: string, error = false) { el('status').textContent = text; el('status').classList.toggle('error', error); }
function setBusy(value: boolean) {
  busy = value;
  document.querySelectorAll<HTMLButtonElement>('[data-job]').forEach(button => button.disabled = value);
  document.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLButtonElement>('#name,#mode,#samples input,#samples button,#sources button,#manual-label').forEach(control => control.disabled = value);
  el<HTMLButtonElement>('cancel').hidden = !value;
  el<HTMLButtonElement>('save').disabled = value || !output;
}
function invalidate() {
  generation++; output = null; clearTimeout(timer);
  if (face) document.fonts.delete(face); face = null;
  el<HTMLButtonElement>('save').disabled = true; el('font-preview').style.fontFamily = 'Gellix';
}
function selectedGlyphs() {
  const result: Record<string, VectorGlyph> = mode === 'captured' ? { ...captured } : { ...inferred, ...captured };
  for (const char of replacements) if (!captured[char] && fallback[char] && mode !== 'captured') result[char] = fallback[char];
  for (const char of excluded) if (!captured[char]) delete result[char];
  if (estimatedSpace) result[' '] = estimatedSpace;
  return result;
}
async function rebuild() {
  if (!metrics || busy) return;
  invalidate(); const run = generation, name = cleanName();
  try {
    const bytes = await buildFont(selectedGlyphs(), metrics, name);
    const family = `MyManFont_${crypto.randomUUID().replaceAll('-', '')}`;
    const builtFace = new FontFace(family, bytes); await builtFace.load();
    if (run !== generation) return;
    face = builtFace; document.fonts.add(face); output = { bytes, name, family, revision: run };
    el('font-preview').style.fontFamily = `"${family}", Gellix`; el<HTMLButtonElement>('save').disabled = false;
    updatePreview(); renderCoverage();
  } catch (error) { if (run === generation) message(String(error), true); }
}
function updatePreview() {
  const text = el<HTMLTextAreaElement>('preview').value;
  el('font-preview').textContent = text;
  el('font-preview').style.fontSize = `${el<HTMLInputElement>('size').value}px`;
  const glyphs = selectedGlyphs(), missing = [...new Set([...text].filter(c => c !== '\n' && !glyphs[c]))];
  el('missing').textContent = missing.length ? `Missing from this export: ${missing.join(' ')}. Preview uses substitute characters for these.` : '';
}
function b64(bytes: Uint8Array) { let value = ''; for (let i = 0; i < bytes.length; i += 8192) value += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(value); }
function samplePNG(sample: Sample) { const c = document.createElement('canvas'); c.width = sample.bitmap.width; c.height = sample.bitmap.height; c.getContext('2d')!.putImageData(sample.bitmap, 0, 0); return c.toDataURL('image/png').split(',')[1]; }
async function loadImage(url: string) { const image = new Image(); image.src = url; await image.decode(); return image; }
async function serialize(): Promise<SavedState> { return { version: 1, name: cleanName(), samples: samples.map(s => { const { bitmap: _, ...rest } = s; return { ...rest, png: samplePNG(s) }; }), excluded: [...excluded], replacements: [...replacements], mode, preview: el<HTMLTextAreaElement>('preview').value }; }

function drawSource() {
  const image = images[selected]?.image; if (!image) return;
  const scale = Math.min(1, 820 / image.naturalWidth, 330 / image.naturalHeight);
  canvas.width = Math.ceil(image.naturalWidth * scale * 2); canvas.height = Math.ceil(image.naturalHeight * scale * 2);
  canvas.style.width = `${canvas.width / 2}px`; canvas.style.height = `${canvas.height / 2}px`;
  const ctx = canvas.getContext('2d')!; ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
  if (selection) { ctx.strokeStyle = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim(); ctx.lineWidth = 4; ctx.strokeRect(selection.x * canvas.width / image.naturalWidth, selection.y * canvas.height / image.naturalHeight, selection.w * canvas.width / image.naturalWidth, selection.h * canvas.height / image.naturalHeight); }
  el('selection-label').textContent = selection ? `${Math.round(selection.w)} × ${Math.round(selection.h)} pixels selected` : 'Drag over the text you want to use, or read the whole screenshot.';
}
function renderSources() {
  el('sources').replaceChildren();
  images.forEach((source, index) => { const button = document.createElement('button'); button.textContent = `Screenshot ${index + 1}`; button.classList.toggle('selected', index === selected); button.disabled = busy; button.onclick = () => { selected = index; selection = null; renderSources(); drawSource(); }; el('sources').append(button); });
  el<HTMLButtonElement>('add').disabled = busy || images.length >= 3;
}
const point = (event: PointerEvent) => { const r = canvas.getBoundingClientRect(), image = images[selected]; return { x: Math.max(0, Math.min(image.width, (event.clientX - r.left) * image.width / r.width)), y: Math.max(0, Math.min(image.height, (event.clientY - r.top) * image.height / r.height)) }; };
canvas.onpointerdown = event => { if (busy || !images.length) return; drag = point(event); selection = null; canvas.setPointerCapture(event.pointerId); };
canvas.onpointermove = event => { if (!drag) return; const p = point(event); selection = { x: Math.min(p.x, drag.x), y: Math.min(p.y, drag.y), w: Math.abs(p.x - drag.x), h: Math.abs(p.y - drag.y) }; drawSource(); };
canvas.onpointerup = () => { drag = null; if (selection && (selection.w < 8 || selection.h < 8)) selection = null; drawSource(); };
el('clear-selection').onclick = () => { selection = null; drawSource(); };

async function read() {
  if (busy || !images.length) return;
  invalidate(); const run = generation; setBusy(true); message('Reading character shapes locally…');
  try {
    const image = images[selected], region = selection ?? { x: 0, y: 0, w: image.width, h: image.height };
    const rect = { x: Math.floor(region.x), y: Math.floor(region.y), w: Math.floor(region.w), h: Math.floor(region.h) };
    const c = document.createElement('canvas'); c.width = rect.w; c.height = rect.h;
    const ctx = c.getContext('2d', { willReadFrequently: true })!;
    ctx.drawImage(image.image!, rect.x, rect.y, rect.w, rect.h, 0, 0, rect.w, rect.h);
    const normalized = normalizeRaster(ctx.getImageData(0, 0, rect.w, rect.h));
    ctx.putImageData(new ImageData(normalized.data, rect.w, rect.h), 0, 0);
    const recognized = await bridge<{ characters: Character[]; truncated: boolean }>('recognize', { png: c.toDataURL('image/png').split(',')[1], generation: run });
    if (run !== generation) return;
    if (!recognized.characters.length) throw new Error('No usable Latin characters found. Try a larger text crop or add a clearer screenshot.');
    const tonal = document.createElement('canvas'); tonal.width = rect.w; tonal.height = rect.h;
    const tone = tonal.getContext('2d', { willReadFrequently: true })!; tone.putImageData(new ImageData(normalized.tonalData, rect.w, rect.h), 0, 0);
    const linePrefix = crypto.randomUUID();
    const additions: Sample[] = recognized.characters.flatMap((character, index) => {
      const box = character.bbox;
      const x = Math.max(0, Math.floor(box.x)), y = Math.max(0, Math.floor(box.y));
      const w = Math.min(rect.w - x, Math.ceil(box.x + box.w) - x), h = Math.min(rect.h - y, Math.ceil(box.y + box.h) - y);
      if (w < 1 || h < 1) return [];
      const bitmap = tone.getImageData(x, y, w, h), ink = inkBounds(bitmap);
      if (!ink) return [];
      // OCR boxes contain inconsistent padding. Locate actual ink, retaining
      // its original image Y so all letters share the measured line baseline.
      const bounds = { x: x + ink.x0, y: y + ink.y0, w: ink.x1 - ink.x0, h: ink.y1 - ink.y0 };
      return [{ id: `${linePrefix}-${index}`, imageId: selected, char: character.char, confidence: character.confidence,
        lineId: `${linePrefix}-${character.lineId}`, bbox: { ...bounds, x: bounds.x + rect.x, y: bounds.y + rect.y },
        bitmap: tone.getImageData(bounds.x, bounds.y, bounds.w, bounds.h), normalized: true }];
    });
    samples = [...samples, ...additions].slice(-1800); renderSamples(); el('review').hidden = false;
    message(`${additions.length} samples added. Check ambiguous labels such as I, l, 1, O and 0.${recognized.truncated ? ' This region contains more text; use a smaller crop for the rest.' : ''}`);
  } catch (error) { if (run === generation) message(String(error), true); }
  finally { if (run === generation) { setBusy(false); renderSources(); } }
}

function renderSamples() {
  el('samples').replaceChildren();
  for (const sample of samples) {
    const card = document.createElement('label'); card.className = 'sample';
    const preview = document.createElement('canvas'); preview.width = sample.bitmap.width; preview.height = sample.bitmap.height;
    preview.getContext('2d')!.putImageData(sample.bitmap, 0, 0); preview.setAttribute('aria-label', 'Captured character');
    const input = document.createElement('input'); input.value = sample.char ?? ''; input.maxLength = 1; input.setAttribute('aria-label', 'Character label; clear to exclude');
    input.oninput = () => { invalidate(); sample.char = /^[\x21-\x7e]$/.test(input.value) ? input.value : null; el('result').hidden = true; };
    const prefer = document.createElement('button'); prefer.type = 'button'; prefer.textContent = sample.preferred ? 'Preferred' : 'Use this'; prefer.title = 'Prefer this occurrence when tracing the character';
    prefer.onclick = event => { event.preventDefault(); for (const other of samples) if (other.char === sample.char) other.preferred = false; sample.preferred = true; invalidate(); renderSamples(); el('result').hidden = true; };
    card.append(preview, input, prefer); el('samples').append(card);
  }
}
async function trace() {
  if (busy) return;
  invalidate(); const run = generation; setBusy(true); message('Tracing captured outlines…');
  try {
    const labeled = samples.filter(s => s.char), estimate = estimateMetrics(labeled); metrics = estimate.metrics;
    const groups = new Map<string, Sample[]>(); for (const sample of labeled) groups.set(sample.char!, [...(groups.get(sample.char!) ?? []), sample]);
    captured = {}; inferred = {}; fallback = {};
    for (const [char, group] of groups) {
      const ranked = rankSamples(group.filter(s => !s.preferred).slice(0, 24));
      for (const sample of [...group.filter(s => s.preferred), ...ranked]) {
        if (run !== generation) return;
        const line = estimate.perCandidate[sample.id];
        const glyph = await vectorizeCandidate(sample, metrics, line.baselineY, line.capHeightPx);
        if (run !== generation) return;
        if (glyph.path) { captured[char] = glyph; break; }
      }
      message(`Tracing ${char} · ${Object.keys(captured).length} captured characters`); await nextFrame();
    }
    if (!Object.keys(captured).length) throw new Error('No usable outlines. Check the labels or choose a clearer text crop.');
    try {
      const completed = await inferMissing(captured, metrics, (char, n, total) => message(`Constructing approximate ${char} · ${n} of ${total}`), () => run !== generation);
      inferred = completed.inferred; estimatedSpace = completed.space;
      el('style-note').textContent = completed.style.limitations.join(' ');
    } catch (error) {
      if (run !== generation) return;
      mode = 'captured'; el<HTMLSelectElement>('mode').value = mode;
      estimatedSpace = { char: ' ', path: '', advanceWidth: 280, xMin: 0, xMax: 0, yMin: 0, yMax: 0, source: 'space' };
      el('style-note').textContent = `${String(error)} Missing letters remain missing.`;
    }
    message('Comparing captured shapes with bundled fonts…');
    const bases = await loadBaseFonts(), matches = rankBaseFonts(bases, captured, metrics);
    if (run !== generation) return;
    candidates = matches.slice(0, 5).map(m => ({ name: m.base.name, distance: m.score, compared: m.compared })); catalogSize = bases.length;
    const picked = pickBaseFont(matches.length ? [matches[0].base] : [], captured, metrics);
    if (picked) for (const char of BASIC_LATIN) if (!captured[char] && char !== ' ') { const glyph = picked.base.glyph(char, picked.adjust); if (glyph) fallback[char] = glyph; }
    await renderMatches(matches.slice(0, 3).map(m => m.base), bases.length, run);
    if (run !== generation) return;
    el('result').hidden = false; message('Captured shapes are preserved. Review approximated letters before exporting.');
    setBusy(false); await rebuild(); el('result').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (error) { if (run === generation) message(String(error), true); }
  finally { if (run === generation) { setBusy(false); renderSources(); } }
}
async function renderMatches(matches: { name: string; url: string }[], count: number, run: number) {
  matchingFaces.forEach(f => document.fonts.delete(f)); matchingFaces = []; el('matches').replaceChildren();
  el('match-note').textContent = `Closest suggestions among ${count} bundled styles. This is a limited comparison, not an exact identification.`;
  for (const match of matches) {
    const card = document.createElement('div'); card.className = 'match'; const title = document.createElement('strong'); title.textContent = match.name;
    const preview = document.createElement('div'); preview.className = 'match-preview'; preview.textContent = 'Aa Bb 012';
    try { const f = new FontFace(`Match_${crypto.randomUUID().replaceAll('-', '')}`, `url("${match.url}")`); await f.load(); if (run !== generation) return; document.fonts.add(f); matchingFaces.push(f); preview.style.fontFamily = f.family; } catch { preview.textContent = 'Preview unavailable'; }
    const original = document.createElement('button'); original.textContent = 'View original ↗'; original.onclick = () => { void bridge('original', { name: match.name }); };
    card.append(title, preview, original); el('matches').append(card);
  }
}
function renderCoverage() {
  const glyphs = selectedGlyphs(); el('coverage').replaceChildren();
  const counts = { traced: 0, inferred: 0, base: 0, space: 0, missing: 0 };
  for (const char of BASIC_LATIN) {
    const glyph = glyphs[char], type = glyph?.source ?? 'missing';
    if (type in counts) counts[type as keyof typeof counts]++;
    const card = document.createElement('div'); card.className = `glyph ${type}`;
    const title = document.createElement('strong'); title.textContent = char === ' ' ? 'Space' : char;
    const preview = document.createElement('div'); preview.className = 'glyph-preview'; preview.textContent = char; if (output) preview.style.fontFamily = output.family;
    const source = document.createElement('span'); source.textContent = ({ traced: 'Captured', inferred: 'Inferred', base: 'External fallback', space: 'Estimated space' } as Record<string, string>)[type] ?? 'Missing';
    card.append(title, preview, source);
    if (glyph?.evidence?.length) { const evidence = document.createElement('small'); evidence.textContent = `From ${glyph.evidence.join(' ')}`; card.append(evidence); }
    if (glyph?.review) card.title = glyph.review;
    if (!captured[char] && char !== ' ') {
      const choice = document.createElement('select'); choice.setAttribute('aria-label', `Source for ${char}`);
      for (const [value, label] of [['inferred', 'Inferred'], ['missing', 'Exclude'], ...(fallback[char] ? [['fallback', `Use ${fallback[char].sourceFont}`]] : [])]) { const o = document.createElement('option'); o.value = value; o.textContent = label; choice.append(o); }
      choice.value = excluded.has(char) ? 'missing' : replacements.has(char) ? 'fallback' : 'inferred'; choice.disabled = mode === 'captured';
      choice.onchange = () => { excluded.delete(char); replacements.delete(char); if (choice.value === 'missing') excluded.add(char); if (choice.value === 'fallback') replacements.add(char); void rebuild(); }; card.append(choice);
    }
    el('coverage').append(card);
  }
  el('counts').textContent = `${counts.traced} captured · ${counts.inferred} inferred · ${counts.base} external fallback · ${counts.space} estimated space · ${counts.missing} missing`;
}
el('read').onclick = () => { void read(); }; el('trace').onclick = () => { void trace(); };
el('manual').onclick = () => {
  const char = el<HTMLInputElement>('manual-label').value;
  if (busy || !selection || !/^[\x21-\x7e]$/.test(char)) { message('Select one complete glyph and enter its character label.', true); return; }
  const c = document.createElement('canvas'), image = images[selected].image!;
  c.width = image.naturalWidth; c.height = image.naturalHeight; const ctx = c.getContext('2d', { willReadFrequently: true })!; ctx.drawImage(image, 0, 0);
  const full = normalizeRaster(ctx.getImageData(0, 0, c.width, c.height)); ctx.putImageData(new ImageData(full.tonalData, c.width, c.height), 0, 0);
  const bbox = { x: Math.floor(selection.x), y: Math.floor(selection.y), w: Math.floor(selection.w), h: Math.floor(selection.h) };
  const id = crypto.randomUUID(); samples.push({ id, imageId: selected, bbox, bitmap: ctx.getImageData(bbox.x, bbox.y, bbox.w, bbox.h), char, confidence: 80, lineId: `manual-${id}`, normalized: true });
  invalidate(); renderSamples(); el('review').hidden = false; message('Manual sample added. Check the crop and create the font again.');
};
el('cancel').onclick = () => { invalidate(); void bridge('cancel'); setBusy(false); message('Cancelled. Your screenshots are unchanged.'); };
el('add').onclick = async () => { try { const added = await bridge<Source[]>('addImages', { remaining: 3 - images.length }); for (const source of added) { source.image = await loadImage(source.url); images.push(source); } selected = Math.max(0, images.length - 1); selection = null; renderSources(); drawSource(); } catch (error) { message(String(error), true); } };
nameInput.oninput = () => { invalidate(); timer = setTimeout(() => { void rebuild(); }, 250); };
el<HTMLSelectElement>('mode').onchange = event => { mode = (event.target as HTMLSelectElement).value; void rebuild(); };
el<HTMLTextAreaElement>('preview').oninput = updatePreview; el<HTMLInputElement>('size').oninput = updatePreview;
el('save').onclick = async () => {
  const current = output; if (!current || current.revision !== generation || busy) return;
  setBusy(true);
  try { const project = await serialize(); if (current.revision !== generation) return;
    const result = await bridge<{ saved: boolean; path?: string }>('save', { font: b64(new Uint8Array(current.bytes)), name: current.name, project, provenance: Object.values(selectedGlyphs()).map(g => ({ char: g.char, source: g.source, evidence: g.evidence ?? [], review: g.review ?? '', sourceFont: g.sourceFont ?? '' })) });
    if (result.saved) { message('Font saved and added to your searchable notes.'); el<HTMLButtonElement>('open-font').hidden = false; }
  } catch (error) { message(String(error), true); } finally { setBusy(false); }
};
el('open-font').onclick = () => { void bridge('openSaved'); };
window.addEventListener('pagehide', () => { invalidate(); matchingFaces.forEach(f => document.fonts.delete(f)); void bridge('cancel').catch(() => {}); });
window.FontEngine = { inferMissing, measureStyle, buildFont, parsePath };
window.fontWorkbench = {
  async start(payload) {
    for (const [key, value] of Object.entries(payload.palette ?? {})) document.documentElement.style.setProperty(`--${key}`, value);
    images = payload.images.slice(0, 3); for (const source of images) source.image = await loadImage(source.url);
    renderSources(); drawSource();
    if (payload.project) {
      const project = payload.project; nameInput.value = project.name; mode = project.mode; el<HTMLSelectElement>('mode').value = mode;
      excluded = new Set(project.excluded); replacements = new Set(project.replacements); el<HTMLTextAreaElement>('preview').value = project.preview;
      samples = await Promise.all(project.samples.map(async s => { const image = await loadImage(`data:image/png;base64,${s.png}`); const c = document.createElement('canvas'); c.width = image.naturalWidth; c.height = image.naturalHeight; const ctx = c.getContext('2d')!; ctx.drawImage(image, 0, 0); const { png: _, ...rest } = s; return { ...rest, bitmap: ctx.getImageData(0, 0, c.width, c.height) }; }));
      renderSamples(); el('review').hidden = false; await trace();
    }
  },
  inspect: () => ({ candidates, catalog_size: catalogSize, status: el('status').textContent, matching: el('match-note').textContent, busy, generation, captured: Object.keys(captured), inferred: Object.keys(inferred), ready: !!output, name: output?.name, font: output ? b64(new Uint8Array(output.bytes)) : null, glyphs: selectedGlyphs(), metrics }),
  exportProject: async () => ({ project: await serialize(), provenance: Object.values(selectedGlyphs()).map(g => ({ char: g.char, source: g.source, evidence: g.evidence ?? [], review: g.review ?? "", sourceFont: g.sourceFont ?? "" })) }),
  run: async (capturedOnly = false) => { mode = capturedOnly ? 'captured' : 'completed'; el<HTMLSelectElement>('mode').value = mode; await read(); if (samples.length) await trace(); },
};
