import { test } from "node:test";
import assert from "node:assert/strict";
import opentype from "opentype.js";
import { normalizeRaster, inkBounds } from "../engine/raster";
import { parsePath, transformPath } from "../engine/paths";
import { estimateMetrics } from "../engine/metrics";
import { buildFont } from "../engine/font";
import type { GlyphCandidate, VectorGlyph } from "../engine/types";

function raster(background: number, ink: number, transparent = false) {
  const width = 20, height = 20, data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const inside = x >= 7 && x < 13 && y >= 3 && y < 17;
    const i = (y * width + x) * 4;
    data[i] = data[i + 1] = data[i + 2] = inside ? ink : background;
    data[i + 3] = transparent && !inside ? 0 : 255;
  }
  return { data, width, height };
}
for (const [name, background, ink, transparent] of [
  ["dark text", 255, 0, false], ["light text", 0, 255, false],
  ["low contrast", 220, 175, false], ["transparent background", 0, 0, true],
] as const) test(`normalizes ${name} without reversing glyph ink`, () => {
  const normalized = normalizeRaster(raster(background, ink, transparent));
  assert.deepEqual(inkBounds(normalized), { x0: 7, y0: 3, x1: 13, y1: 17, count: 84 });
});

test("blank screenshots contain no glyphs", () => {
  assert.equal(inkBounds(normalizeRaster(raster(255, 255))), null);
});

test("SVG parser handles relative coordinates and implicit line segments", () => {
  const p = parsePath("m10 20 30 0 v40 h-30z");
  assert.deepEqual(p.commands, [{ type: "M", x: 10, y: 20 }, { type: "L", x: 40, y: 20 }, { type: "L", x: 40, y: 60 }, { type: "L", x: 10, y: 60 }, { type: "Z" }]);
  const transformed = transformPath(p, 2, -2, 5, 100).getBoundingBox();
  assert.deepEqual([transformed.x1, transformed.y1, transformed.x2, transformed.y2], [25, -20, 85, 60]);
});

test("malformed outlines fail instead of silently losing coordinates", () => {
  for (const path of ["M 10", "M0 0 C1 2", "M 0 0 A 5 5 0 0 0 10 10", "M0 0 @ L3 4"]) assert.throws(() => parsePath(path));
});

function candidate(id: string, char: string, lineId: string, y: number, h: number): GlyphCandidate {
  return { id, char, lineId, imageId: 0, bbox: { x: 0, y, w: 20, h }, bitmap: {} as ImageData, confidence: 99 };
}
const samples = [candidate("H1", "H", "title", 20, 70), candidate("x1", "x", "title", 40, 50), candidate("g1", "g", "title", 40, 68), candidate("H2", "H", "body", 200, 35), candidate("x2", "x", "body", 210, 25), candidate("quote", "'", "body", 200, 8)];

test("different text sizes keep independent line scales and baselines", () => {
  const result = estimateMetrics(samples);
  assert.deepEqual(result.perCandidate.H1, { baselineY: 90, capHeightPx: 70 });
  assert.deepEqual(result.perCandidate.H2, { baselineY: 235, capHeightPx: 35 });
  assert.equal(result.metrics.xHeight, 500);
  assert.equal((result.perCandidate.g1.baselineY - 108) * 10, -180);
  assert.equal((result.perCandidate.quote.baselineY - 208) * 20, 540);
});

const outline: VectorGlyph = { char: "O", path: "M50 0L50 700L450 700L450 0Z M100 50L400 50L400 650L100 650Z", advanceWidth: 500, xMin: 50, xMax: 450, yMin: 0, yMax: 700, source: "traced" };
test("export round-trips as real OpenType with holes, spacing and character mappings", async () => {
  const { metrics } = estimateMetrics(samples);
  const buf = await buildFont({ O: outline, "'": { ...outline, char: "'", path: "M50 540L50 760L100 760L100 540Z", advanceWidth: 150 } }, metrics, "Regression Font");
  assert.equal(Buffer.from(buf).subarray(0, 4).toString(), "OTTO");
  const font = opentype.parse(buf);
  assert.equal(font.names.fontFamily.en, "Regression Font");
  assert.equal(font.charToGlyph("O").advanceWidth, 500);
  assert.equal(font.charToGlyph(" ").advanceWidth, 280);
  assert.equal(font.charToGlyph("O").path.commands.filter(c => c.type === "M").length, 2);
  assert.ok(font.ascender >= 760);
  assert.equal(font.charToGlyphIndex("?"), 0);
  assert.ok(font.glyphs.get(0).path.commands.length > 0);
});

test("font assembly rejects blank output, invalid labels and nonfinite spacing", async () => {
  const { metrics } = estimateMetrics(samples);
  await assert.rejects(buildFont({}, metrics, "Empty"));
  await assert.rejects(buildFont({ AB: outline }, metrics, "Bad label"));
  await assert.rejects(buildFont({ O: { ...outline, advanceWidth: NaN } }, metrics, "Bad spacing"));
});

test("repeated-letter consensus rejects a confident crop containing extra ink", async () => {
  const { rankSamples } = await import("../engine/samples");
  const good = normalizeRaster(raster(255, 0));
  const bad = normalizeRaster(raster(255, 0));
  for (let y = 4; y < 15; y++) for (let x = 0; x < 6; x++) {
    const i = (y * 20 + x) * 4; bad.data[i] = bad.data[i + 1] = bad.data[i + 2] = 0;
  }
  const make = (id: string, confidence: number, bitmap: typeof good) => ({ ...candidate(id, "I", "line", 0, 20), confidence, bitmap: { ...bitmap, colorSpace: "srgb" as const } });
  const ranked = rankSamples([make("contaminated", 100, bad), make("clean1", 96, good), make("clean2", 95, good)]);
  assert.equal(ranked[0].id, "clean1");
});

test("bundled font specimens parse and contain the expected alphabets", async () => {
  const { readFileSync, readdirSync } = await import("node:fs");
  for (const name of readdirSync(new URL("../../../src/Resources/FontWorkbench/fonts", import.meta.url)).filter(name => name.endsWith(".ttf"))) {
    const data = readFileSync(new URL(`../../../src/Resources/FontWorkbench/fonts/${name}`, import.meta.url));
    const font = opentype.parse(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
    for (const char of "AaOg09!?") assert.ok(font.charToGlyphIndex(char) > 0, `${name} contains ${char}`);
  }
});

test("tracing retains intermediate antialias tones while OCR receives binary pixels", () => {
  const source = raster(255, 0);
  const edge = (5 * 20 + 7) * 4;
  source.data[edge] = source.data[edge + 1] = source.data[edge + 2] = 120;
  const normalized = normalizeRaster(source);
  assert.ok(normalized.tonalData[edge] > 0 && normalized.tonalData[edge] < 255);
  assert.ok(normalized.data[edge] === 0 || normalized.data[edge] === 255);
});

test("baseline comes from flat feet rather than round-letter overshoot", () => {
  const input = [candidate("H", "H", "line", 20, 70), candidate("n", "n", "line", 40, 50), candidate("O", "O", "line", 19, 73), candidate("o", "o", "line", 39, 53), candidate("I", "I", "line", 20, 70), candidate("p", "p", "line", 40, 68)];
  const { perCandidate } = estimateMetrics(input);
  for (const sample of input) assert.equal(perCandidate[sample.id].baselineY, 90);
  assert.equal(perCandidate.O.capHeightPx, 70);
  assert.equal(perCandidate.p.baselineY, 90); // descender remains below zero
});
