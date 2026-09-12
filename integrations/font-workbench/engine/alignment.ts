import type { FontMetrics, VectorGlyph } from './types';
import { parsePath, transformPath } from './paths';
import { clamp, median } from './style';

/** Raster rounding is significant at caption sizes. Register traced letters
 * to common type metrics before mixing them with larger samples or inference.
 * This changes vertical placement/scale, never the character's topology, width
 * or spacing. Punctuation and the distinctive shorter f/t/dotted i/j stay put. */
export function alignCaptured(glyphs: Record<string, VectorGlyph>, metrics: FontMetrics): Record<string, VectorGlyph> {
  const ascender = median(Object.values(glyphs).filter(g => /^[bdhkl]$/.test(g.char)).map(g => g.yMax), metrics.capHeight);
  const optical = metrics.capHeight * .018;
  const result: Record<string, VectorGlyph> = {};
  for (const [char, glyph] of Object.entries(glyphs)) {
    const height = /^[A-Z0-9]$/.test(char) ? metrics.capHeight
      : /^[acegmnopqrsuvwxyz]$/.test(char) ? metrics.xHeight
      : /^[bdhkl]$/.test(char) ? ascender : 0;
    if (glyph.source !== 'traced' || !height || !glyph.path || glyph.yMax <= 0 || glyph.yMax <= glyph.yMin) {
      result[char] = glyph; continue;
    }
    const curvedTop = /^[CGOQS03689aceos]$/.test(char);
    const top = height + (curvedTop ? clamp(glyph.yMax - height, 0, optical) : 0);
    let sy: number, dy = 0;
    if (/^[gjpqyQJ]$/.test(char)) {
      // Scale about the baseline, so a tail remains below it instead of being
      // pulled up to the feet of ordinary letters.
      sy = top / glyph.yMax;
    } else {
      const flatFoot = /^[AEFHIKLMNTVWXYZ147hiklmnrvwxz]$/.test(char);
      const bottom = flatFoot ? 0 : clamp(glyph.yMin, -optical, 0);
      sy = (top - bottom) / (glyph.yMax - glyph.yMin);
      dy = bottom - glyph.yMin * sy;
    }
    const path = transformPath(parsePath(glyph.path), 1, sy, 0, dy);
    const box = path.getBoundingBox();
    result[char] = { ...glyph, path: path.toPathData(2), xMin: box.x1, xMax: box.x2, yMin: box.y1, yMax: box.y2 };
  }
  return result;
}
