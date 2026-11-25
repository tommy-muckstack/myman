import test from 'node:test';
import assert from 'node:assert/strict';
import { run } from '../app-cli.mjs';

// The flags an agent uses for a window capture, checked without an app.
async function sent(argv) {
  const calls = [];
  await run(argv, { env: {}, invoke: async (name, args) => { calls.push({ name, args }); return { ok: true, result: {} }; } });
  return calls;
}

test('--window passes a name through and --no-ocr turns the sidecar off', async () => {
  assert.deepEqual(await sent(['screenshot', '--mode', 'agent', '--window', 'Safari', '--json']), [{ name: 'screenshot.capture', args: { window: 'Safari' } }]);
  assert.deepEqual(await sent(['screenshot', '--mode', 'agent', '--window', 'Safari', '--no-ocr', '--json']), [{ name: 'screenshot.capture', args: { window: 'Safari', ocr: false } }]);
});

test('the catalog advertises window and ocr for screenshot.capture', async () => {
  const { catalog } = await import('../actions.mjs');
  const action = catalog.actions.find(a => a.name === 'screenshot.capture');
  assert.ok(action.inputSchema.properties.window); assert.equal(action.inputSchema.properties.ocr.type, 'boolean');
});
