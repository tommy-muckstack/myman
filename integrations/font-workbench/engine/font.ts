import opentype from "opentype.js";
import type { VectorGlyph, FontMetrics } from "./types";
import { parsePath } from "./paths";

export async function buildFont(glyphs: Record<string, VectorGlyph>, metrics: FontMetrics, familyName: string): Promise<ArrayBuffer> {
  if (!Number.isFinite(metrics.unitsPerEm) || metrics.unitsPerEm < 16 || metrics.unitsPerEm > 16384) throw new Error("Invalid font size");
  const missing = parsePath("M 60 0 L 60 700 L 440 700 L 440 0 Z M 110 50 L 390 50 L 390 650 L 110 650 Z");
  const list = [
    new opentype.Glyph({ name: ".notdef", advanceWidth: 500, path: missing }),
    new opentype.Glyph({ name: "space", unicode: 32, advanceWidth: glyphs[" "]?.advanceWidth ?? 280, path: new opentype.Path() }),
  ];
  let ascent = Math.max(700, metrics.ascent), descent = Math.min(-1, metrics.descent);
  for (const [char, g] of Object.entries(glyphs).sort(([a], [b]) => a.codePointAt(0)! - b.codePointAt(0)!)) {
    if (char === " ") continue;
    if ([...char].length !== 1 || !g.path.trim()) throw new Error(`Invalid outline for ${char}`);
    if (!Number.isFinite(g.advanceWidth) || g.advanceWidth <= 0) throw new Error(`Invalid spacing for ${char}`);
    const path = parsePath(g.path);
    const box = path.getBoundingBox();
    if (![box.x1, box.x2, box.y1, box.y2].every(Number.isFinite)) throw new Error(`Invalid bounds for ${char}`);
    ascent = Math.max(ascent, Math.ceil(box.y2)); descent = Math.min(descent, Math.floor(box.y1));
    const code = char.codePointAt(0)!;
    list.push(new opentype.Glyph({ name: `uni${code.toString(16).toUpperCase().padStart(4, "0")}`, unicode: code, advanceWidth: Math.round(g.advanceWidth), path }));
  }
  if (list.length < 3) throw new Error("No usable outlines. Review the recognized letters or add a clearer screenshot.");
  const sources = Object.values(glyphs).filter(g => g.source === "base");
  const notices = [...new Set(sources.map(g => g.license).filter(Boolean))].join("\n\n");
  const copyright = [...new Set(sources.map(g => g.copyright).filter(Boolean))].join("\n");
  const inference = Object.values(glyphs).filter(g => g.source === "inferred").length;
  const description = `${inference} characters approximated from measured sample style. ` + (sources.length ? `Screenshot outlines with fallback characters from ${[...new Set(sources.map(g => g.sourceFont).filter(Boolean))].join(", ")}. Included notices apply to fallback characters.` : "Visible characters traced from screenshot samples.");
  const font = new opentype.Font({ license: notices, copyright, description, familyName: familyName.trim() || "Screenshot Font", styleName: "Regular", unitsPerEm: metrics.unitsPerEm, ascender: ascent, descender: descent, glyphs: list });
  // opentype.js 1.x writes CFF outlines (OTTO), hence the .otf extension.
  return font.toArrayBuffer();
}

export function downloadFont(buf: ArrayBuffer, filename: string) {
  const blob = new Blob([buf], { type: "font/otf" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  const clean = filename.replace(/\.(ttf|otf)$/i, "").replace(/[<>:"/\\|?*\x00-\x1f]/g, "_").trim() || "Screenshot Font";
  a.download = `${clean}.otf`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
