import type { GlyphCandidate, VectorGlyph, FontMetrics } from "./types";
import { inkBounds, normalizeRaster } from "./raster";
import { parsePath, transformPath } from "./paths";

export async function vectorizeCandidate(
  cand: GlyphCandidate,
  metrics: FontMetrics,
  baselineY: number,
  capHeightPx: number,
): Promise<VectorGlyph> {
  const empty: VectorGlyph = { char: cand.char ?? "", path: "", advanceWidth: 500, xMin: 0, yMin: 0, xMax: 0, yMax: 0, source: "traced" };
  const normalized = cand.normalized ? cand.bitmap : normalizeRaster(cand.bitmap);
  const ink = inkBounds(normalized);
  if (!ink || !cand.char) return empty;
  // Explicit white margin keeps edge-touching stems from becoming background.
  const padding = 2;
  const source = document.createElement("canvas");
  source.width = normalized.width + padding * 2;
  source.height = normalized.height + padding * 2;
  const ctx = source.getContext("2d")!;
  ctx.fillStyle = "white"; ctx.fillRect(0, 0, source.width, source.height);
  ctx.putImageData(new ImageData(new Uint8ClampedArray(normalized.data), normalized.width, normalized.height), padding, padding);
  const scale = Math.min(4, Math.max(1, 240 / source.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(source.width * scale); canvas.height = Math.ceil(source.height * scale);
  const up = canvas.getContext("2d")!;
  up.fillStyle = "white"; up.fillRect(0, 0, canvas.width, canvas.height);
  up.imageSmoothingEnabled = true; up.imageSmoothingQuality = "high";
  up.drawImage(source, 0, 0, source.width * scale, source.height * scale);
  const data = up.getImageData(0, 0, canvas.width, canvas.height);
  for (let i = 0; i < data.data.length; i += 4) {
    const value = data.data[i] < 128 ? 0 : 255;
    data.data[i] = data.data[i + 1] = data.data[i + 2] = value;
  }
  const mod = await import("imagetracerjs");
  const tracer = mod.default || mod;
  const svg: string = tracer.imagedataToSVG(data, {
    ltres: 0.5, qtres: 0.5, pathomit: 0, colorsampling: 0, numberofcolors: 2,
    pal: [{ r: 0, g: 0, b: 0, a: 255 }, { r: 255, g: 255, b: 255, a: 255 }],
    strokewidth: 0, linefilter: false, rightangleenhance: false, roundcoords: 2,
  });
  // ImageTracer includes correctly wound hole contours in each dark path.
  // Preserve every contour: dots, punctuation and simple rectangles are valid.
  const paths: string[] = [];
  for (const match of svg.matchAll(/<path\b([^>]*)>/g)) {
    const attrs = match[1];
    if (!/fill="rgb\(0,0,0\)"/.test(attrs)) continue;
    const d = attrs.match(/\sd="([^"]*)"/)?.[1];
    if (d) paths.push(d);
  }
  if (!paths.length) return empty;
  const unitsPerPx = metrics.capHeight / Math.max(1, capHeightPx);
  const factor = unitsPerPx / scale;
  const baseline = baselineY - cand.bbox.y + padding;
  const path = transformPath(parsePath(paths.join(" ")), factor, -factor, 0, baseline * unitsPerPx);
  const box = path.getBoundingBox();
  const bearing = Math.round(metrics.capHeight * 0.06);
  const shifted = transformPath(path, 1, 1, bearing - box.x1);
  const bounds = shifted.getBoundingBox();
  return {
    char: cand.char, path: shifted.toPathData(2),
    advanceWidth: Math.max(1, Math.round(bounds.x2 + bearing)),
    xMin: bounds.x1, xMax: bounds.x2, yMin: bounds.y1, yMax: bounds.y2,
    source: "traced", inkDensity: ink.count / ((ink.x1 - ink.x0) * (ink.y1 - ink.y0)),
  };
}
