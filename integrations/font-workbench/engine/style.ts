import { parsePath } from "./paths";
import type { FontMetrics, VectorGlyph } from "./types";

export const median = (a: number[], fallback = 0) => {
  const values = a.filter(Number.isFinite).sort((x, y) => x - y);
  return values.length ? values[Math.floor(values.length / 2)] : fallback;
};
export const clamp = (x: number, low: number, high: number) => Math.max(low, Math.min(high, x));
export const widths: Record<string, number> = { I: .3, J: .6, M: 1.3, W: 1.45, T: .9, F: .8, L: .8, i: .24, l: .25, j: .35, f: .5, t: .5, r: .65, m: 1.55, w: 1.4 };

export interface SampleStyle {
  capHeight: number; xHeight: number; ascender: number; descender: number;
  stem: number; horizontal: number; slant: number; capWidth: number; lowerWidth: number;
  bearing: number; bowlPower: number; serif: number; bracketed: boolean; roundTerminals: boolean;
  evidence: string[]; stemEvidence: string[]; bowlEvidence: string[]; limitations: string[];
}

function mask(g: VectorGlyph) {
  const canvas = document.createElement("canvas"), scale = 160 / Math.max(1, g.yMax - g.yMin);
  canvas.width = Math.ceil((g.xMax - g.xMin) * scale) + 4; canvas.height = 164;
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  ctx.fillStyle = "white"; ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.translate(2 - g.xMin * scale, 162 + g.yMin * scale); ctx.scale(scale, -scale);
  ctx.fillStyle = "black"; ctx.fill(new Path2D(g.path));
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
  const at = (x: number, y: number) => x >= 0 && y >= 0 && x < canvas.width && y < canvas.height && data[(y * canvas.width + x) * 4] < 128;
  const runs = (index: number, vertical = false) => {
    const out: number[] = []; let run = 0;
    for (let i = 0; i <= (vertical ? canvas.height : canvas.width); i++) {
      if (vertical ? at(index, i) : at(i, index)) run++;
      else if (run) { out.push(run / scale); run = 0; }
    }
    return out;
  };
  const edges = (y: number) => {
    const xs = Array.from({ length: canvas.width }, (_, x) => x).filter(x => at(x, y));
    return xs.length ? [xs[0] / scale, xs[xs.length - 1] / scale] : [];
  };
  return { runs, edges, width: canvas.width, scale };
}

/** Only original captured outlines enter the profile. Never learn from a
 * fallback face, hidden target, or a previously inferred character. */
export function measureStyle(glyphs: Record<string, VectorGlyph>, metrics: FontMetrics): SampleStyle {
  const captured = Object.values(glyphs).filter(g => g.source === "traced" && g.path && /[A-Za-z0-9]/.test(g.char));
  if (!captured.length) throw new Error("Capture at least one letter or digit to infer a style. Captured-only export is still available.");
  const cap = metrics.capHeight, xHeight = metrics.xHeight;
  const vertical: number[] = [], horizontal: number[] = [], slants: number[] = [], serifs: number[] = [], bowls: number[] = [], terminals: number[] = [];
  const stemEvidence: string[] = [], bowlEvidence: string[] = [];
  for (const g of captured) {
    const m = mask(g);
    if (/[HIEFlhnbdpqomO0]/.test(g.char)) {
      const runs = [40, 65, 100, 120].flatMap(y => m.runs(y)).filter(v => v > cap * .018 && v < cap * .26);
      if (runs.length) { vertical.push(median(runs)); stemEvidence.push(g.char); }
    }
    if (/[HEFTeosO0]/.test(g.char)) horizontal.push(...[.25, .45, .65].flatMap(x => m.runs(Math.floor(m.width * x), true)).filter(v => v > cap * .015 && v < cap * .22));
    if (/[IlH]/.test(g.char)) {
      const top = m.edges(35), bottom = m.edges(125);
      if (top.length && bottom.length) slants.push((top[0] - bottom[0]) / (90 / m.scale));
    }
    if (/[Il]/.test(g.char)) {
      const tip = m.edges(3), shaft = m.edges(14);
      if (tip.length && shaft.length) terminals.push(1 - (tip[1] - tip[0]) / Math.max(1, shaft[1] - shaft[0]));
    }
    if (/[Ilnh]/.test(g.char)) {
      const top = m.edges(8), middle = m.edges(70), bottom = m.edges(155);
      if (middle.length && bottom.length) serifs.push(Math.max(0, middle[0] - bottom[0], top.length ? middle[0] - top[0] : 0));
    }
    if (/[Oo0]/.test(g.char)) {
      const quarter = m.edges(42), middle = m.edges(82);
      if (quarter.length && middle.length) { bowls.push((quarter[1] - quarter[0]) / Math.max(1, middle[1] - middle[0])); bowlEvidence.push(g.char); }
    }
  }
  const capWidths = captured.filter(g => /[A-Z0-9]/.test(g.char)).map(g => (g.xMax - g.xMin) / (widths[g.char] ?? 1));
  const lowerWidths = captured.filter(g => /[a-z]/.test(g.char)).map(g => (g.xMax - g.xMin) / (widths[g.char] ?? 1));
  const lowerWidth = clamp(median(lowerWidths, median(capWidths, cap * .67) * .82), cap * .25, cap * 1.1);
  const stem = clamp(median(vertical, cap * .09), cap * .025, cap * .23);
  const thin = clamp(median(horizontal, stem * .9), stem * .22, stem * 1.15);
  const serif = clamp(median(serifs), 0, stem * 1.8);
  const limitations = ["Unseen letter anatomy is approximate; kerning, ligatures and alternates are not recovered."];
  if (captured.length < 6) limitations.push("Sparse evidence: proportions and terminals need review.");
  if (!bowlEvidence.length) limitations.push("No captured round letter: bowl shape is estimated.");
  if (serifs.length < 2) limitations.push("Limited stem-terminal evidence: serif shape is uncertain.");
  return {
    capHeight: cap, xHeight,
    ascender: median(captured.filter(g => /[bdfhkl]/.test(g.char)).map(g => g.yMax), cap),
    descender: Math.abs(median(captured.filter(g => /[gjpqy]/.test(g.char)).map(g => g.yMin).filter(y => y < 0), -cap * .25)),
    stem, horizontal: thin, slant: clamp(median(slants), -.35, .35),
    capWidth: clamp(median(capWidths, lowerWidth / .82), cap * .3, cap * 1.3), lowerWidth,
    bearing: clamp(median(captured.map(g => (g.advanceWidth - g.xMax + g.xMin) / 2), cap * .06), cap * .02, cap * .18),
    bowlPower: clamp(2 + (median(bowls, .866) - .866) * 10, 1.7, 3.1),
    serif: serif > stem * .15 ? serif : 0, bracketed: stem / thin > 1.8,
    roundTerminals: !serif && median(terminals) > .15, evidence: captured.map(g => g.char).sort(), stemEvidence, bowlEvidence, limitations,
  };
}
