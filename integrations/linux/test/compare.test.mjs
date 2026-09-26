import assert from 'node:assert/strict';
import test from 'node:test';
import { changedText, difference, targetRegions } from '../compare.mjs';
import { parseTsv } from '../desktop.mjs';

const image = (w, h, paint = () => [255, 255, 255]) => { const b = Buffer.alloc(w * h * 3); for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) b.set(paint(x, y), (y * w + x) * 3); return b; };

test('pixel difference matches the Mac rules: threshold, ignore rects, 32px regions', () => {
  const a = image(100, 80), b = image(100, 80, (x, y) => (x >= 10 && x < 20 && y >= 5 && y < 15) || (x >= 70 && y >= 60) ? [0, 0, 0] : [255, 255, 255]);
  const d = difference(a, b, 100, 80, [], 20);
  assert.equal(d.compared, 8000); assert.equal(d.changed, 100 + 30 * 20);
  assert.deepEqual(d.regions, [[0, 0, 32, 32], [64, 32, 36, 48]]);
  const faint = image(100, 80, () => [240, 240, 240]);
  assert.equal(difference(a, faint, 100, 80, [], 20).changed, 0, 'changes at or under the threshold are ignored');
  const ignored = difference(a, b, 100, 80, [[64, 32, 36, 48]], 20);
  assert.equal(ignored.changed, 100); assert.equal(ignored.compared, 8000 - 36 * 48);
  const all = difference(a, b, 100, 80, [[0, 0, 100, 80]], 20);
  assert.equal(all.changed, 0); assert.equal(all.compared, 0);
});

test('changed text lists added and removed lines outside ignored areas', () => {
  const before = [{ text: 'Save', rect: [0, 0, 40, 10] }, { text: 'Clock 9:00', rect: [0, 50, 40, 10] }];
  const after = [{ text: 'Saved', rect: [0, 0, 40, 10] }, { text: 'Clock 9:01', rect: [0, 50, 40, 10] }];
  assert.deepEqual(changedText(before, after, []), { removed: ['Clock 9:00', 'Save'], added: ['Clock 9:01', 'Saved'] });
  assert.deepEqual(changedText(before, after, [[0, 45, 100, 20]]), { removed: ['Save'], added: ['Saved'] });
});

test('targets have stable IDs for lines and words', () => {
  const tsv = 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n5\t1\t1\t1\t1\t1\t10\t20\t50\t12\t95\tOpen\n5\t1\t1\t1\t1\t2\t64\t20\t60\t12\t93\tSettings\n';
  const lines = parseTsv(tsv, { words: true }), again = parseTsv(tsv, { words: true });
  const [line] = targetRegions(lines);
  assert.equal(line.text, 'Open Settings'); assert.deepEqual(line.rect, [10, 20, 114, 12]); assert.match(line.id, /^ocr-[0-9a-f]{24}$/);
  assert.equal(targetRegions(again)[0].id, line.id);
  const words = targetRegions(lines, 'word');
  assert.deepEqual(words.map(w => w.text), ['Open', 'Settings']); assert.deepEqual(words[1].rect, [64, 20, 60, 12]); assert.match(words[1].id, /^word-ocr-/);
});
