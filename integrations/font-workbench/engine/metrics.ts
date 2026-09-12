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
  // Learn proportions from lines containing both cases before estimating
  // lowercase-only lines. A fixed .72 ratio made body text disagree with titles.
  const ratios: number[] = [], ascenderRatios: number[] = [];
  for (const line of lines.values()) {
    const caps = line.filter(c => /^[AEFHIKLMNTVWXYZ147]$/.test(c.char!));
    for (const cap of caps) {
      const nearby = line.filter(c => Math.abs(c.bbox.y + c.bbox.h - cap.bbox.y - cap.bbox.h) <= Math.max(2, cap.bbox.h * .06));
      const nearest = (pattern: RegExp, low: number, high: number) => nearby.filter(c => pattern.test(c.char!) && c.bbox.h / cap.bbox.h >= low && c.bbox.h / cap.bbox.h <= high)
        .sort((a, b) => Math.abs(a.bbox.x - cap.bbox.x) - Math.abs(b.bbox.x - cap.bbox.x))[0]?.bbox.h ?? 0;
      const x = nearest(/^[mnrvwxz]$/, .4, .95);
      const asc = nearest(/^[bdhkl]$/, .85, 1.3);
      if (x / cap.bbox.h >= .4 && x / cap.bbox.h <= .95) ratios.push(x / cap.bbox.h);
      if (asc / cap.bbox.h >= .85 && asc / cap.bbox.h <= 1.3) ascenderRatios.push(asc / cap.bbox.h);
    }
  }
  const learnedX = median(ratios) || .72, learnedAscender = median(ascenderRatios) || 1;
  const runs: GlyphCandidate[][] = [];
  for (const line of lines.values()) {
    // Vision can put differently sized runs on the same line. Cluster actual
    // resting letters by size and baseline, then attach punctuation/descenders
    // to their nearest run instead of treating their height as a font size.
    const groups: { samples: GlyphCandidate[]; sizes: number[]; bottoms: number[] }[] = [];
    const unanchored: GlyphCandidate[] = [];
    for (const c of line) {
      const ratio = /^[A-IK-PR-Z0-9]$/.test(c.char!) ? 1 : /^[acemnorsuvwxz]$/.test(c.char!) ? learnedX : /^[bdhkl]$/.test(c.char!) ? learnedAscender : 0;
      if (!ratio) { unanchored.push(c); continue; }
      const size = c.bbox.h / ratio, bottom = c.bbox.y + c.bbox.h;
      let group = groups.find(g => Math.abs(Math.log(size / median(g.sizes))) < .18 && Math.abs(bottom - median(g.bottoms)) <= Math.max(2, size * .12));
      if (!group) { group = { samples: [], sizes: [], bottoms: [] }; groups.push(group); }
      group.samples.push(c); group.sizes.push(size); group.bottoms.push(bottom);
    }
    for (const c of unanchored) {
      const distance = (g: typeof groups[number]) => Math.min(...g.samples.map(other => Math.abs(c.bbox.x + c.bbox.w / 2 - other.bbox.x - other.bbox.w / 2)));
      const nearest = [...groups].sort((a, b) => distance(a) - distance(b))[0];
      if (nearest) nearest.samples.push(c);
    }
    runs.push(...(groups.length ? groups.map(g => g.samples) : [line]));
  }
  for (const line of runs) {
    const caps = line.filter(c => /^[A-Z0-9]$/.test(c.char!));
    const xLetters = line.filter(c => /^[acemnorsuvwxz]$/.test(c.char!));
    const ascenders = line.filter(c => /^[bdhkl]$/.test(c.char!));
    const flatCaps = caps.filter(c => /^[AEFHIKLMNTVWXYZ147]$/.test(c.char!));
    const capHeightPx = median(flatCaps.map(c => c.bbox.h)) || median(caps.map(c => c.bbox.h)) || median(ascenders.map(c => c.bbox.h)) / learnedAscender || median(xLetters.map(c => c.bbox.h)) / learnedX || median(line.map(c => c.bbox.h));
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
