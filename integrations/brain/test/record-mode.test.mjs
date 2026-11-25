import test from 'node:test';
import assert from 'node:assert/strict';
import { plan } from '../app-cli.mjs';

test('record start --mode narration routes to narration.start', async () => {
  const p = await plan(['record', 'start', '--mode', 'narration', '--label', 'section-2', '--json']);
  assert.equal(p.name, 'narration.start');
  assert.equal(p.args.label, 'section-2');
});

test('record stop --mode narration routes to narration.stop', async () => {
  const p = await plan(['record', 'stop', '--mode', 'narration', '--json']);
  assert.equal(p.name, 'narration.stop');
});

test('record start --mode clip routes to clip.record', async () => {
  const p = await plan(['record', 'start', '--mode', 'clip', '--window-id', '42', '--max-duration', '20', '--json']);
  assert.equal(p.name, 'clip.record');
});

test('an unknown record mode is rejected', async () => {
  await assert.rejects(plan(['record', 'start', '--mode', 'movie', '--json']), /Mode must be interactive or agent/);
});
