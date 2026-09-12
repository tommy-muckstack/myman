// Loads bundled open-source fonts and exposes their glyphs in our internal
// font-units coordinate system, rescaled to match the traced font's measured
// proportions. Used as a fallback whenever a letter couldn't be traced or
// derived, so every target char ships with some glyph in the final TTF.
//
// The goal is "looks like the same font as the traced letters" — not just
// "drops Inter into the gaps." We measure width, height, and stem proportions
// from the traced glyphs and apply matching scale factors to every base glyph.

import type { Font } from "opentype.js";
import type { VectorGlyph, FontMetrics } from "./types";

export interface BaseFont {
  name: string;
  glyph: (ch: string, adj?: StyleAdjustment) => VectorGlyph | null;
  style: BaseFontStyle;
  url: string;
}

export interface BaseFontStyle {
  inkDensity: number; // actual rasterized-and-counted ink density (0-1)
  xHeightRatio: number; // x-height / cap-height
  xWidthMean: number; // mean lowercase-letter width (font units, cap-height frame)
  capWidthMean: number; // mean uppercase-letter width (font units, cap-height frame)
  // Serif-ness proxy: 'I' width / cap-height. Sans ~0.10, serif ~0.25+.
  serifness: number;
  // Width uniformity: stdev/mean of cap widths. Geometric fonts have uniform
  // widths (low value), humanist/display fonts have varied widths (higher).
  widthUniformity: number;
}

export interface StyleAdjustment {
  xScaleLower: number; // multiplier applied to lowercase a-z glyph widths
  xScaleUpper: number; // multiplier applied to uppercase A-Z glyph widths
  xScaleDigit: number; // multiplier applied to digit glyph widths
}

// WKWebView does not expose arbitrary custom schemes through fetch. Native
// asset loading is limited to the packaged font/license allowlist.
async function localResource(url: string): Promise<Response> {
  if (typeof window !== "undefined" && window.location.protocol === "myman-font:") {
    const encoded = await window.webkit.messageHandlers.font.postMessage({ action: "fontAsset", path: url }) as string;
    return new Response(Uint8Array.from(atob(encoded), c => c.charCodeAt(0)));
  }
  return fetch(url);
}
let cached: Promise<BaseFont[]> | null = null;

export function loadBaseFonts(): Promise<BaseFont[]> {
  if (cached) return cached;
  cached = (async () => {
    const opentype =
      (await import("opentype.js")).default || (await import("opentype.js"));
    const basePath =
      typeof window !== "undefined" &&
      window.location.pathname.startsWith("/font-clone")
        ? "/font-clone/fonts"
        : "/fonts";
    const urls: { name: string; url: string }[] = [
      // Humanist sans — narrower letters, slightly more varied widths
      { name: "Inter Light", url: `${basePath}/Inter-Light.ttf` },
      { name: "Inter Regular", url: `${basePath}/Inter-Regular.ttf` },
      { name: "Inter Medium", url: `${basePath}/Inter-Medium.ttf` },
      { name: "Inter SemiBold", url: `${basePath}/Inter-SemiBold.ttf` },
      { name: "Inter Bold", url: `${basePath}/Inter-Bold.ttf` },
      // Geometric sans — wider, more uniform letter widths (Futura/Avenir-like)
      { name: "Poppins Regular", url: `${basePath}/Poppins-Regular.ttf` },
      { name: "Poppins Bold", url: `${basePath}/Poppins-Bold.ttf` },
      // Serif — serifs add noticeable width, especially to thin letters
      { name: "Noto Serif Regular", url: `${basePath}/NotoSerif-Regular.ttf` },
      { name: "Noto Serif Bold", url: `${basePath}/NotoSerif-Bold.ttf` },
      { name: "Lato Regular", url: `${basePath}/Lato-Regular.ttf` },
      { name: "Montserrat Regular", url: `${basePath}/Montserrat-Regular.ttf` },
      { name: "Open Sans Regular", url: `${basePath}/OpenSans-Regular.ttf` },
      { name: "Playfair Display Regular", url: `${basePath}/PlayfairDisplay-Regular.ttf` },
      { name: "Oswald Regular", url: `${basePath}/Oswald-Regular.ttf` },
      { name: "Raleway Regular", url: `${basePath}/Raleway-Regular.ttf` },
      // Slab serif — thick horizontal serifs, very distinct silhouette
      { name: "Roboto Slab", url: `${basePath}/RobotoSlab-Regular.ttf` },
    ];
    const out: BaseFont[] = [];
    const licenseLoads = new Map<string, Promise<string>>();
    const licenseFor = (name: string) => {
      const family = name.replace(/ (Regular|Light|Medium|SemiBold|Bold)$/, "").replaceAll(" ", "").toLowerCase();
      if (!licenseLoads.has(family)) licenseLoads.set(family, localResource(`${basePath}/licenses/${family}-${family === "robotoslab" ? "LICENSE" : "OFL"}.txt`).then(async response => {
        if (!response.ok) throw new Error(`Missing font license: ${family}`);
        return response.text();
      }));
      return licenseLoads.get(family)!;
    };
    const fetched = await Promise.all(
      urls.map(async ({ name, url }) => {
        try {
          const response = await localResource(url);
          if (!response.ok) throw new Error(`Font request failed: ${response.status}`);
          const buf = await response.arrayBuffer();
          return { name, url, license: await licenseFor(name), font: opentype.parse(buf) };
        } catch (e) {
          console.warn(`[basefont] failed to load ${name}:`, e);
          return null;
        }
      }),
    );
    for (const f of fetched) {
      if (f) out.push(buildBaseFont(f.name, f.font, f.url, f.license));
    }
    return out;
  })();
  return cached;
}

const TARGET_CAP = 700;
const SIDE_BEARING = Math.round(TARGET_CAP * 0.08);

function buildBaseFont(name: string, font: Font, url: string, license: string): BaseFont {
  const unitsPerEm = font.unitsPerEm as number;
  const xHeight =
    (font.tables.os2 && font.tables.os2.sxHeight) || unitsPerEm * 0.5;
  const capHeight =
    (font.tables.os2 && font.tables.os2.sCapHeight) || unitsPerEm * 0.7;
  const nativeToTarget = TARGET_CAP / Math.max(capHeight, 1);

  const widthIn = (ch: string): number => {
    const g = font.charToGlyph(ch);
    if (!g) return 0;
    const bb = g.getBoundingBox();
    return (bb.x2 - bb.x1) * nativeToTarget;
  };

  const mean = (chars: string): number => {
    const ws = chars.split("").map(widthIn).filter((w) => w > 0);
    return ws.length ? ws.reduce((a, b) => a + b, 0) / ws.length : 0;
  };

  const capWidths = "ACDEGHKMNOPQRSUVWXYZ".split("").map(widthIn).filter((w) => w > 0);
  const capMean = capWidths.length ? capWidths.reduce((a, b) => a + b, 0) / capWidths.length : 0;
  const capVar = capWidths.length
    ? capWidths.reduce((s, w) => s + (w - capMean) ** 2, 0) / capWidths.length
    : 0;
  const capStdev = Math.sqrt(capVar);

  const iWidth = widthIn("I");
  // Serifness = I-width / cap-height. Sans I is just a stem (~0.08-0.12).
  // Serif I carries serifs at top and bottom that extend outward significantly
  // (~0.25-0.40). Slab is usually even higher.
  const serifness = iWidth / TARGET_CAP;

  const style: BaseFontStyle = {
    inkDensity: measureInkDensity(font),
    xHeightRatio: xHeight / Math.max(capHeight, 1),
    xWidthMean: mean("aceimnoprsuvwxz"),
    capWidthMean: capMean,
    serifness,
    widthUniformity: capMean > 0 ? capStdev / capMean : 0,
  };

  return {
    name,
    url,
    style,
    glyph: (ch: string, adj?: StyleAdjustment) => {
      const glyph = glyphFor(font, ch, { capHeight }, adj);
      return glyph ? { ...glyph, sourceFont: name, license, copyright: font.names.copyright?.en ?? "" } : null;
    },
  };
}

// Rasterize a representative sample letter, tight-crop to ink bbox, and count
// ink ratio. Same signal as vectorize.ts inkDensity (ink / tight-bbox-area)
// so base-font and traced densities are directly comparable.
function measureInkDensity(font: Font): number {
  if (typeof document === "undefined") return 0.5;
  // Rasterize each letter of a representative sample separately and average.
  const sample = "aeonrs";
  const densities: number[] = [];
  for (const ch of sample) {
    const d = measureCharDensity(font, ch);
    if (d != null) densities.push(d);
  }
  return densities.length
    ? densities.reduce((a, b) => a + b, 0) / densities.length
    : 0.5;
}

function measureCharDensity(font: Font, ch: string): number | null {
  const canvas = document.createElement("canvas");
  const W = 120, H = 120;
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext("2d")!;
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, W, H);
  try {
    const path = font.getPath(ch, 20, 80, 64);
    path.fill = "#000";
    path.draw(ctx);
  } catch {
    return null;
  }
  const img = ctx.getImageData(0, 0, W, H);
  let minX = W, maxX = -1, minY = H, maxY = -1, ink = 0;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const lum = 0.299 * img.data[i] + 0.587 * img.data[i + 1] + 0.114 * img.data[i + 2];
      if (lum < 127) {
        ink++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  const bboxArea = (maxX - minX + 1) * (maxY - minY + 1);
  return ink / Math.max(1, bboxArea);
}

interface BaseFontMetrics {
  capHeight: number;
}

function glyphFor(
  font: Font,
  ch: string,
  bm: BaseFontMetrics,
  adj?: StyleAdjustment,
): VectorGlyph | null {
  const glyph = font.charToGlyph(ch);
  if (!glyph || glyph.name === ".notdef") return null;
  const path = glyph.path;
  if (!path || !path.commands || path.commands.length === 0) return null;

  // Pick the right category x-scale based on what kind of character this is,
  // so uppercase / lowercase / digit can each have their own match to traced
  // widths.
  const isUpper = ch >= "A" && ch <= "Z";
  const isLower = ch >= "a" && ch <= "z";
  const isDigit = ch >= "0" && ch <= "9";
  const xScale = adj
    ? isUpper
      ? adj.xScaleUpper
      : isLower
      ? adj.xScaleLower
      : isDigit
      ? adj.xScaleDigit
      : 1
    : 1;
  // Cap-height and x-height scale MUST stay identical between traced and
  // base-font glyphs so they read as the same font family. Only x is
  // per-category adjusted; y is always the native→target scale so caps land
  // exactly at 700 font units like traced caps do.
  const nativeToTarget = TARGET_CAP / Math.max(bm.capHeight, 1);
  const sx = nativeToTarget * xScale;
  const sy = nativeToTarget;

  let xMin = Infinity, yMin = Infinity, xMax = -Infinity, yMax = -Infinity;
  let d = "";
  const track = (x: number, y: number) => {
    if (x < xMin) xMin = x;
    if (x > xMax) xMax = x;
    if (y < yMin) yMin = y;
    if (y > yMax) yMax = y;
  };
  for (const cmd of path.commands) {
    switch (cmd.type) {
      case "M": {
        const x = cmd.x * sx, y = cmd.y * sy;
        d += `M ${x.toFixed(1)} ${y.toFixed(1)} `;
        track(x, y);
        break;
      }
      case "L": {
        const x = cmd.x * sx, y = cmd.y * sy;
        d += `L ${x.toFixed(1)} ${y.toFixed(1)} `;
        track(x, y);
        break;
      }
      case "C": {
        const x1 = cmd.x1 * sx, y1 = cmd.y1 * sy;
        const x2 = cmd.x2 * sx, y2 = cmd.y2 * sy;
        const x = cmd.x * sx, y = cmd.y * sy;
        d += `C ${x1.toFixed(1)} ${y1.toFixed(1)} ${x2.toFixed(1)} ${y2.toFixed(1)} ${x.toFixed(1)} ${y.toFixed(1)} `;
        track(x, y);
        break;
      }
      case "Q": {
        const x1 = cmd.x1 * sx, y1 = cmd.y1 * sy;
        const x = cmd.x * sx, y = cmd.y * sy;
        d += `Q ${x1.toFixed(1)} ${y1.toFixed(1)} ${x.toFixed(1)} ${y.toFixed(1)} `;
        track(x, y);
        break;
      }
      case "Z":
        d += "Z ";
        break;
    }
  }
  if (!isFinite(xMin)) return null;

  const shift = SIDE_BEARING - xMin;
  if (shift !== 0) d = shiftX(d, shift);
  const shiftedXMax = Math.round(xMax - xMin + SIDE_BEARING);
  const nativeAdvance = (glyph.advanceWidth || bm.capHeight * 0.5) * sx;
  const advance = Math.max(shiftedXMax + SIDE_BEARING, Math.round(nativeAdvance));

  return {
    char: ch,
    path: d.trim(),
    advanceWidth: advance,
    xMin: SIDE_BEARING,
    yMin: Math.round(yMin),
    xMax: shiftedXMax,
    yMax: Math.round(yMax),
    source: "base",
  };
}

function shiftX(d: string, dx: number): string {
  const tokens = d.match(/[MLCQZ]|-?\d*\.?\d+(?:e[-+]?\d+)?/g) || [];
  let out = "";
  let i = 0;
  while (i < tokens.length) {
    const cmd = tokens[i++];
    if (!/^[MLCQZ]$/.test(cmd)) continue;
    if (cmd === "Z") {
      out += "Z ";
      continue;
    }
    const nums: number[] = [];
    while (i < tokens.length && !/^[MLCQZ]$/.test(tokens[i])) {
      nums.push(parseFloat(tokens[i++]));
    }
    const pairs = cmd === "C" ? 3 : cmd === "Q" ? 2 : 1;
    for (let k = 0; k < nums.length; k += pairs * 2) {
      out += cmd + " ";
      for (let p = 0; p < pairs; p++) {
        const xi = k + p * 2;
        out += (nums[xi] + dx).toFixed(1) + " " + nums[xi + 1].toFixed(1) + " ";
      }
    }
  }
  return out.trim();
}

// Measure the traced font's style. Returns null for any metric that can't be
// measured reliably.
export interface TracedStyle {
  xWidthMean: number | null;
  capWidthMean: number | null;
  xHeightRatio: number;
  inkDensity: number | null; // 0-1, fraction of ink in binarized bitmap
  serifness: number | null; // I-width / cap-height; sans ~0.1, serif ~0.25+
  widthUniformity: number | null; // stdev/mean of cap widths
}

export function measureTracedStyle(
  glyphs: Record<string, VectorGlyph>,
  metrics: FontMetrics,
): TracedStyle {
  const tracedOf = (chars: string): number[] => {
    const out: number[] = [];
    for (const ch of chars) {
      const g = glyphs[ch];
      if (!g || g.source !== "traced") continue;
      const w = Math.abs(g.xMax - g.xMin);
      if (w > 0) out.push(w);
    }
    return out;
  };
  const avg = (xs: number[]): number | null =>
    xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;

  const densities: number[] = [];
  for (const g of Object.values(glyphs)) {
    if (g.source === "traced" && typeof g.inkDensity === "number") {
      densities.push(g.inkDensity);
    }
  }
  const inkDensity = densities.length
    ? densities.reduce((a, b) => a + b, 0) / densities.length
    : null;

  // Serifness: I-width / cap-height if we traced an I/l (thin letters whose
  // bbox width is dominated by any serifs they have).
  const iWidths = tracedOf("Il");
  const serifness = iWidths.length
    ? Math.min(...iWidths) / Math.max(metrics.capHeight, 1)
    : null;

  const capWidths = tracedOf("ACDEGHKMNOPQRSUVWXYZ");
  const capMean = capWidths.length
    ? capWidths.reduce((a, b) => a + b, 0) / capWidths.length
    : 0;
  const capStdev = capWidths.length
    ? Math.sqrt(
        capWidths.reduce((s, w) => s + (w - capMean) ** 2, 0) / capWidths.length,
      )
    : 0;

  return {
    xWidthMean: avg(tracedOf("aceinoprsuvwxz")),
    capWidthMean: capMean || null,
    xHeightRatio: metrics.xHeight / Math.max(metrics.capHeight, 1),
    inkDensity,
    serifness,
    widthUniformity: capMean > 0 ? capStdev / capMean : null,
  };
}

// Score a base font against the traced style. Lower = better match. We can't
// transmogrify a sans into a serif with xScale, so style-level signals
// (serifness, width uniformity) dominate. Within a matching style group,
// ink-density picks the right weight.
function scoreBase(base: BaseFont, traced: TracedStyle): number {
  let score = 0;

  // Serifness is categorical: serif fonts need a serif base, sans needs sans.
  // The gap between Inter's I-width (~0.08 cap) and Noto Serif's (~0.30+) is
  // huge, so a large multiplier makes this dominate.
  if (traced.serifness != null) {
    score += Math.abs(base.style.serifness - traced.serifness) * 40;
  }

  // Ink density (weight matching).
  if (traced.inkDensity != null) {
    score += Math.abs(base.style.inkDensity - traced.inkDensity) * 20;
  }

  // Width uniformity: geometric sans (Poppins) has low uniformity value,
  // humanist (Inter) higher. Helps distinguish Poppins from Inter for
  // geometric-looking screenshots.
  if (traced.widthUniformity != null) {
    score += Math.abs(base.style.widthUniformity - traced.widthUniformity) * 8;
  }

  // x-height ratio tie-breaker.
  score += Math.abs(base.style.xHeightRatio - traced.xHeightRatio) * 3;

  return score;
}

// Pick the base font that best matches traced style, and return the scale
// adjustments that bring its glyph proportions into alignment with the traced
// letters. Uppercase, lowercase, and digits each get their own x-scale so the
// base-font letters adopt the actual widths of the traced sibling category.
export function pickBaseFont(
  bases: BaseFont[],
  tracedGlyphs: Record<string, VectorGlyph>,
  metrics: FontMetrics,
): { base: BaseFont; adjust: StyleAdjustment } | null {
  if (!bases.length) return null;
  const traced = measureTracedStyle(tracedGlyphs, metrics);

  const base = rankBaseFonts(bases, tracedGlyphs, metrics)[0].base;

  // Per-category width matching. For each category (lower/upper/digit) we
  // compute: (traced mean width) / (base font mean width). Clamps are loose
  // enough (0.7-1.4) to actually match geometric sans proportions — the old
  // 0.75-1.25 was too tight and left Inter looking too narrow next to traced
  // letters from rounder, wider fonts.
  const ratio = (traced: number | null, baseMean: number, fallback = 1) => {
    if (traced == null || baseMean <= 0) return fallback;
    return clamp(traced / baseMean, 0.7, 1.4);
  };
  // Compare the SAME characters; comparing a screenshot of "iii" with the
  // average width of an entire alphabet systematically selects the wrong fit.
  const matchedRatio = (pattern: RegExp, fallback: number) => {
    const values = Object.values(tracedGlyphs).filter(g => g.source === "traced" && pattern.test(g.char)).flatMap(g => {
      const b = base.glyph(g.char);
      return b && b.xMax > b.xMin ? [(g.xMax - g.xMin) / (b.xMax - b.xMin)] : [];
    }).sort((a, b) => a - b);
    return values.length ? clamp(values[Math.floor(values.length / 2)], 0.7, 1.4) : fallback;
  };
  const xScaleLower = matchedRatio(/^[a-z]$/, ratio(traced.xWidthMean, base.style.xWidthMean));
  const xScaleUpper = matchedRatio(/^[A-Z]$/, xScaleLower);
  // Digits: no traced measurement here (we don't sample digit widths),
  // so inherit the uppercase scale — digits and caps typically share widths
  // in sans-serif fonts.
  const xScaleDigit = xScaleUpper;

  console.log(
    `[basefont] traced ink=${traced.inkDensity?.toFixed(2) ?? "?"} serif=${traced.serifness?.toFixed(2) ?? "?"} unif=${traced.widthUniformity?.toFixed(2) ?? "?"} → picked ${base.name} (ink=${base.style.inkDensity.toFixed(2)} serif=${base.style.serifness.toFixed(2)} unif=${base.style.widthUniformity.toFixed(2)}) xScale lower=${xScaleLower.toFixed(2)} upper=${xScaleUpper.toFixed(2)}`,
  );

  return {
    base,
    adjust: { xScaleLower, xScaleUpper, xScaleDigit },
  };
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

// Compare the actual silhouettes of the same reference characters. Width is
// fitted separately; this score distinguishes bowls, terminals and serifs.
function outlineScore(base: BaseFont, glyphs: Record<string, VectorGlyph>): number {
  if (typeof document === "undefined") return 0;
  const canvas = document.createElement("canvas"); canvas.width = 48; canvas.height = 64;
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  const raster = (g: VectorGlyph) => {
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, 48, 64);
    const sx = 44 / Math.max(1, g.xMax - g.xMin), sy = 60 / Math.max(1, g.yMax - g.yMin);
    ctx.setTransform(sx, 0, 0, -sy, 2 - g.xMin * sx, 2 + g.yMax * sy);
    ctx.fill(new Path2D(g.path));
    return ctx.getImageData(0, 0, 48, 64).data;
  };
  const scores: number[] = [];
  for (const g of Object.values(glyphs).filter(g => g.source === "traced" && /^[A-Za-z0-9]$/.test(g.char)).slice(0, 24)) {
    const other = base.glyph(g.char); if (!other) continue;
    const a = raster(g), b = raster(other);
    let union = 0, difference = 0;
    for (let i = 3; i < a.length; i += 4) {
      const inkA = a[i] > 127, inkB = b[i] > 127;
      if (inkA || inkB) union++;
      if (inkA !== inkB) difference++;
    }
    if (union) scores.push(difference / union);
  }
  return scores.length ? scores.reduce((sum, v) => sum + v, 0) / scores.length : 0;
}

export interface FontMatch {
  base: BaseFont;
  score: number;
  compared: number;
}

export function rankBaseFonts(bases: BaseFont[], glyphs: Record<string, VectorGlyph>, metrics: FontMetrics): FontMatch[] {
  const style = measureTracedStyle(glyphs, metrics);
  const compared = Math.min(24, Object.values(glyphs).filter(g => g.source === "traced" && /^[A-Za-z0-9]$/.test(g.char)).length);
  return bases.map(base => ({ base, compared, score: scoreBase(base, style) * (compared >= 5 ? 0.02 : 0.15) + outlineScore(base, glyphs) * 12 })).sort((a, b) => a.score - b.score);
}
