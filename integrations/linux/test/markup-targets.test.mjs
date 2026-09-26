import assert from 'node:assert/strict';
import test from 'node:test';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { resolveTargets } from '../compare.mjs';
import { importFormat, importImage, validateMarkup } from '../images.mjs';
import { imageCommand, run } from '../system.mjs';

const fixture = async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'myman-targets-')), file = path.join(dir, 'ui.png');
  await run(await imageCommand(), ['-size', '900x300', 'xc:white', '-font', 'DejaVu-Sans', '-pointsize', '40', '-fill', 'black',
    '-annotate', '+60+100', 'Save changes', '-annotate', '+480+100', 'Cancel', '-annotate', '+60+220', 'Save draft', file]);
  return { dir, file };
};

test('target_text resolves like the Mac: exact word, 6px padding, arrow to center', async () => {
  const { file } = await fixture();
  const [box, arrow] = await resolveTargets(file, [{ type: 'box', target_text: 'CANCEL' }, { type: 'arrow', target_text: 'Save draft' }], 900, 300);
  assert.equal(box.target_text, undefined); assert.equal(box.rect.length, 4);
  assert.ok(box.rect[0] > 450 && box.rect[0] < 480 && box.rect[2] > 100, `box around Cancel: ${box.rect}`);
  assert.ok(arrow.to[1] > 170 && arrow.to[1] < 230 && arrow.from[0] >= 2 && arrow.from[1] >= 2, `arrow into Save draft: ${arrow.to} from ${arrow.from}`);
  validateMarkup({ annotations: [box, arrow] }, 900, 300);
});

test('ambiguous or missing targets fail with candidates and change nothing', async () => {
  const { file } = await fixture();
  await assert.rejects(resolveTargets(file, [{ type: 'box', target_text: 'save' }], 900, 300), e => e.code === 'AMBIGUOUS_TARGET' && e.details.total === 2 && e.details.candidates.every(c => c.id.startsWith('word-ocr-')));
  await assert.rejects(resolveTargets(file, [{ type: 'box', target_text: 'Delete everything' }], 900, 300), e => e.code === 'TARGET_NOT_FOUND' && e.details.total === 0);
  await assert.rejects(resolveTargets(file, [{ type: 'box', target_text: 'Cancel', rect: [0, 0, 5, 5] }], 900, 300), e => e.code === 'INVALID_ARGUMENTS');
  await assert.rejects(resolveTargets(file, [{ type: 'box', target_region: 'ocr-000000000000000000000000' }], 900, 300), e => e.code === 'TARGET_NOT_FOUND');
});

test('target_region selects a stable region id from a previous ambiguous answer', async () => {
  const { file } = await fixture();
  const e = await resolveTargets(file, [{ type: 'box', target_text: 'save' }], 900, 300).catch(error => error);
  const pick = e.details.candidates.sort((a, b) => a.rect[1] - b.rect[1])[1];
  const [box] = await resolveTargets(file, [{ type: 'highlight', target_region: pick.id }], 900, 300);
  assert.ok(box.rect[1] > 150, 'second Save (the draft row) was chosen');
});

test('import accepts only raster formats by content, never by extension', async () => {
  assert.equal(importFormat(Buffer.from('89504e470d0a1a0a0000', 'hex')), 'png');
  assert.equal(importFormat(Buffer.from('ffd8ffe000', 'hex')), 'jpeg');
  assert.equal(importFormat(Buffer.from('GIF89a....')), 'gif');
  assert.equal(importFormat(Buffer.from('RIFF\0\0\0\0WEBPVP8 ')), 'webp');
  assert.equal(importFormat(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>')), null);
  const { dir, file } = await fixture(), svg = path.join(dir, 'trick.png');
  await writeFile(svg, '<svg xmlns="http://www.w3.org/2000/svg"/>');
  await assert.rejects(importImage(svg, dir), e => e.code === 'INVALID_ARGUMENTS');
  await assert.rejects(importImage('relative.png', dir), e => e.code === 'INVALID_ARGUMENTS');
  const work = await mkdtemp(path.join(os.tmpdir(), 'myman-import-'));
  const out = await importImage(file, work);
  assert.deepEqual([out.width, out.height, out.source_format], [900, 300, 'png']);
});
