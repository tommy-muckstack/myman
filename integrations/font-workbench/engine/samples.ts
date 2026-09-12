import type { GlyphCandidate } from "./types";

/** Repeated letters should agree in shape. Prefer the sample most similar to
 * its peers, avoiding a high-confidence OCR box containing a neighbor's ink. */
export function rankSamples(samples: GlyphCandidate[]): GlyphCandidate[] {
  const masks = samples.map(sample => {
    const mask = new Uint8Array(32 * 48);
    const { width, height, data } = sample.bitmap;
    for (let y = 0; y < 48; y++) for (let x = 0; x < 32; x++) {
      const i = (Math.min(height - 1, Math.floor((y + 0.5) * height / 48)) * width + Math.min(width - 1, Math.floor((x + 0.5) * width / 32))) * 4;
      mask[y * 32 + x] = data[i] < 128 && data[i + 3] > 0 ? 1 : 0;
    }
    return mask;
  });
  const scores = samples.map((sample, i) => {
    let similarity = 0;
    for (let j = 0; j < masks.length; j++) {
      if (i === j) continue;
      let union = 0, overlap = 0;
      for (let p = 0; p < masks[i].length; p++) { if (masks[i][p] || masks[j][p]) union++; if (masks[i][p] && masks[j][p]) overlap++; }
      similarity += union ? overlap / union : 0;
    }
    return { sample, score: (samples.length > 2 ? similarity / (samples.length - 1) : 0) + sample.confidence / 1000 + Math.min(sample.bbox.h, 200) / 10000 };
  });
  return scores.sort((a, b) => b.score - a.score).map(item => item.sample);
}
