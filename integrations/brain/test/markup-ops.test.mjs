import test from 'node:test';
import assert from 'node:assert/strict';
import { plan } from '../app-cli.mjs';
const ops = value => plan(['annotate', '--id', 'shot-x', '--ops', JSON.stringify(value)]);
test('annotate ops accept op or the schema name type', async () => {
  const a = await ops([{ op: 'box', rect: [1, 1, 5, 5] }]), b = await ops([{ type: 'box', rect: [1, 1, 5, 5] }]);
  assert.deepEqual(a.args.annotations, b.args.annotations);
  assert.equal(b.args.annotations[0].type, 'box');
  assert.deepEqual((await ops([{ type: 'text', at: [3, 4], text: 'hi' }])).args.annotations[0].rect, [3, 4, 1, 1]);
});
test('annotate ops explain bad input', async () => {
  await assert.rejects(ops([{ op: 'box', type: 'arrow', rect: [1, 1, 5, 5] }]), /op or type, not both/);
  await assert.rejects(ops([{ rect: [1, 1, 5, 5] }]), /needs op/);
  await assert.rejects(ops([{ op: 'box', at: [1, 2] }]), /at is only for text; use rect for box/);
});
