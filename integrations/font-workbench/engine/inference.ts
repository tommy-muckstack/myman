import tracer from "imagetracerjs";
import { BASIC_LATIN, type FontMetrics, type VectorGlyph } from "./types";
import { parsePath, transformPath } from "./paths";
import { clamp, measureStyle, widths, type SampleStyle } from "./style";
import { skeleton } from "./skeletons";

function construct(char: string, style: SampleStyle): VectorGlyph | null {
  const strokes = skeleton(char, style.bowlPower);
  if (!strokes.length) return null;
  const lower = /^[a-z]$/.test(char), height = lower ? style.xHeight : style.capHeight;
  let width = (lower ? style.lowerWidth : style.capWidth) * (widths[char] ?? 1);
  if (/[.,:;'!|`]/.test(char)) width = style.stem * 1.6;
  if (/[[\](){}]/.test(char)) width *= .5;
  if (char === '"') width *= .45;
  const pad = style.capHeight * .45, scale = .65;
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil((width + pad * 2) * scale);
  canvas.height = Math.ceil((style.ascender + style.descender + pad * 2) * scale);
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  ctx.fillStyle = "white"; ctx.fillRect(0, 0, canvas.width, canvas.height);
  const originY = style.ascender + pad;
  ctx.translate(pad * scale, originY * scale); ctx.scale(scale, -scale);
  ctx.transform(1, 0, style.slant, 1, 0, 0);
  ctx.fillStyle = "black"; ctx.strokeStyle = "black";
  const mapY = (y: number) => lower ? y < 0 ? y / .4 * style.descender : y > 1 ? height + (y - 1) / .4 * (style.ascender - height) : y * height : y * height;
  for (const stroke of strokes) {
    const path = parsePath(stroke);
    for (const c of path.commands) {
      if (c.type === "Z") continue;
      c.x *= width; c.y = mapY(c.y);
      if (c.type === "C" || c.type === "Q") { c.x1 *= width; c.y1 = mapY(c.y1); }
      if (c.type === "C") { c.x2 *= width; c.y2 = mapY(c.y2); }
    }
    // An elliptical pen gives vertical/horizontal stroke contrast without
    // changing the skeleton's anatomy or copying a matching font's outline.
    ctx.save(); ctx.scale(style.stem, style.horizontal);
    ctx.lineWidth = 1; ctx.lineJoin = "round"; ctx.lineCap = style.roundTerminals || /[.,:;!?'"ij]/.test(char) ? "round" : "butt";
    ctx.stroke(new Path2D(transformPath(path, 1 / style.stem, 1 / style.horizontal).toPathData(3)));
    ctx.restore();
    if (style.serif && /[A-Za-z]/.test(char)) {
      const points = path.commands.filter(c => c.type !== "Z");
      for (const index of [0, points.length - 1]) {
        const end = points[index], neighbor = points[index === 0 ? 1 : points.length - 2];
        if (!end || !neighbor || Math.abs(end.x - neighbor.x) > style.stem || Math.abs(end.y - neighbor.y) < height * .2) continue;
        const sign = end.y < height * .25 ? 1 : -1;
        const half = style.stem / 2 + style.serif, thickness = Math.max(style.horizontal * .5, style.capHeight * .018);
        ctx.beginPath(); ctx.moveTo(end.x - half, end.y); ctx.lineTo(end.x + half, end.y);
        ctx.lineTo(end.x + (style.bracketed ? style.stem / 2 : half), end.y + sign * thickness);
        ctx.lineTo(end.x - (style.bracketed ? style.stem / 2 : half), end.y + sign * thickness); ctx.closePath(); ctx.fill();
      }
    }
  }
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
  for (let p = 0; p < data.data.length; p += 4) { const c = data.data[p] < 128 ? 0 : 255; data.data[p] = data.data[p + 1] = data.data[p + 2] = c; }
  const svg: string = tracer.imagedataToSVG(data, { ltres: .4, qtres: .4, pathomit: 0, colorsampling: 0, numberofcolors: 2, pal: [{ r: 0, g: 0, b: 0, a: 255 }, { r: 255, g: 255, b: 255, a: 255 }], strokewidth: 0, rightangleenhance: false, roundcoords: 2 });
  const outlines = [...svg.matchAll(/<path\b([^>]*)>/g)].filter(m => /fill="rgb\(0,0,0\)"/.test(m[1])).map(m => m[1].match(/\sd="([^"]*)"/)?.[1] ?? "").filter(Boolean);
  if (!outlines.length) return null;
  const path = transformPath(parsePath(outlines.join(" ")), 1 / scale, -1 / scale, -pad, originY);
  const bounds = path.getBoundingBox();
  if (![bounds.x1, bounds.x2, bounds.y1, bounds.y2].every(Number.isFinite) || bounds.x2 <= bounds.x1 || bounds.y2 <= bounds.y1) return null;
  // Pen strokes straddle the skeleton's baseline. Normalize inferred letters
  // to the measured baseline instead of letting half a stroke hang below it.
  // Preserve intentional descenders and small round-letter optical overshoot.
  let aligned = path;
  if (/^[A-Za-z0-9]$/.test(char)) {
    const overshoot = /[CGOSU03689bcdeos]/.test(char) ? style.capHeight * .012 : 0;
    const bottom = /[gjpqyQ]/.test(char) ? -style.descender : -overshoot;
    const top = lower ? /[bdfhijklt]/.test(char) ? style.ascender : style.xHeight : style.capHeight;
    const sy = (top + overshoot - bottom) / (bounds.y2 - bounds.y1);
    aligned = transformPath(path, 1, sy, 0, bottom - bounds.y1 * sy);
  }
  const shifted = transformPath(aligned, 1, 1, style.bearing - bounds.x1), box = shifted.getBoundingBox();
  const related = /[bcdgopqOQCG0689]/.test(char) ? style.bowlEvidence : style.stemEvidence;
  return {
    char, path: shifted.toPathData(2), advanceWidth: Math.ceil(box.x2 + style.bearing),
    xMin: box.x1, xMax: box.x2, yMin: box.y1, yMax: box.y2, source: "inferred",
    evidence: [...new Set([...related, ...style.stemEvidence, ...style.evidence.slice(0, 8)])],
    review: style.evidence.length < 6 || /[ag&@]/.test(char) || !related.length
      ? "Weakly supported anatomy. Review or add a captured sample."
      : "Approximate target anatomy adapted to captured weight, proportions, spacing and terminals.",
  };
}

export async function inferMissing(captured: Record<string, VectorGlyph>, metrics: FontMetrics,
  progress: (char: string, done: number, total: number) => void = () => {}, cancelled: () => boolean = () => false) {
  const style = measureStyle(captured, metrics), inferred: Record<string, VectorGlyph> = {};
  const targets = BASIC_LATIN.filter(c => c !== " " && !captured[c]);
  for (const [index, char] of targets.entries()) {
    if (cancelled()) throw new Error("Cancelled");
    const glyph = construct(char, style);
    if (glyph) inferred[char] = glyph;
    progress(char, index + 1, targets.length);
    if (index % 8 === 7) await new Promise(resolve => setTimeout(resolve, 0));
  }
  const space: VectorGlyph = { char: " ", path: "", advanceWidth: clamp(style.lowerWidth * .5 + style.bearing, metrics.capHeight * .2, metrics.capHeight * .65), xMin: 0, xMax: 0, yMin: 0, yMax: 0, source: "space", evidence: style.evidence, review: "Estimated word spacing" };
  return { style, inferred, space };
}
