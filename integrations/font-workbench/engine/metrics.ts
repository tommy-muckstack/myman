import type { GlyphCandidate, FontMetrics, ImageMetrics } from "./types";

const median = (values: number[]) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return (sorted[Math.floor((sorted.length - 1) / 2)] + sorted[Math.floor(sorted.length / 2)]) / 2;
};

/** Each text line has its own baseline AND pixel scale. A title and a caption
 * in one screenshot must not share a cap-height or absolute y coordinate. */
export function estimateMetrics(candidates: GlyphCandidate[]): {
  metrics: FontMetrics;
  perImage: Record<number, ImageMetrics>;
  perCandidate: Record<string, ImageMetrics>;
} {
  const lines = new Map<string, GlyphCandidate[]>();
  for (const c of candidates.filter(c => c.char)) {
    const key = `${c.imageId}:${c.lineId ?? "default"}`;
    lines.set(key, [...(lines.get(key) ?? []), c]);
  }
  const perImage: Record<number, ImageMetrics> = {};
  const perCandidate: Record<string, ImageMetrics> = {};
  const xRatios: number[] = [], descRatios: number[] = [], ascRatios: number[] = [];
  for (const line of lines.values()) {
    const caps = line.filter(c => /^[A-Z0-9]$/.test(c.char!));
    const xLetters = line.filter(c => /^[acemnorsuvwxz]$/.test(c.char!));
    const ascenders = line.filter(c => /^[bdhkl]$/.test(c.char!));
    const flatCaps = caps.filter(c => /^[AEFHIKLMNTVWXYZ147]$/.test(c.char!));
    const capHeightPx = median(flatCaps.map(c => c.bbox.h)) || median(caps.map(c => c.bbox.h)) || median(ascenders.map(c => c.bbox.h)) || median(xLetters.map(c => c.bbox.h)) / 0.72 || median(line.map(c => c.bbox.h));
    const resting = [...caps.filter(c => c.char !== "Q" && c.char !== "J"), ...xLetters, ...ascenders];
    const flatResting = resting.filter(c => /^[AEFHIKLMNTVWXYZ147hilkmnrx]$/.test(c.char!));
    const baselineY = median(flatResting.map(c => c.bbox.y + c.bbox.h)) || median(resting.map(c => c.bbox.y + c.bbox.h)) || median(line.map(c => c.baselineY ?? NaN).filter(Number.isFinite)) || median(line.map(c => c.bbox.y + c.bbox.h));
    const im = { baselineY, capHeightPx };
    perImage[line[0].imageId] ??= im;
    for (const c of line) {
      // Use the shared measured line baseline. This keeps punctuation floating
      // at its original height and preserves true descender proportions.
      perCandidate[c.id] = im;
      ascRatios.push((baselineY - c.bbox.y) / capHeightPx);
      descRatios.push((c.bbox.y + c.bbox.h - baselineY) / capHeightPx);
    }
    if (xLetters.length) xRatios.push(median(xLetters.map(c => c.bbox.h)) / capHeightPx);
  }
  const capHeight = 700;
  const xRatio = median(xRatios) || 0.72;
  return {
    metrics: {
      unitsPerEm: 1000, capHeight, xHeight: Math.round(capHeight * Math.max(0.4, Math.min(0.95, xRatio))),
      ascent: Math.ceil(capHeight * Math.max(1.05, ...ascRatios)),
      descent: -Math.ceil(capHeight * Math.max(0.25, ...descRatios)), baselineY: 0,
    }, perImage, perCandidate,
  };
}
