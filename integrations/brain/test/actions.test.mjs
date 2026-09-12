import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtemp, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { catalog, describe, invoke, request } from '../actions.mjs';

test('discovery is offline and all actions have strict schemas and effect annotations', () => {
  assert.ok(catalog.actions.length >= 35);
  assert.equal(new Set(catalog.actions.map(a => a.name)).size, catalog.actions.length);
  for (const action of catalog.actions) { assert.equal(action.inputSchema.additionalProperties, false); assert.equal(typeof action.readOnly, 'boolean'); assert.equal(typeof action.destructive, 'boolean'); }
  assert.equal(describe('item.delete').destructive, true);
  assert.throws(() => describe('shell.exec'), { code: 'UNKNOWN_ACTION' });
});

test('invoke submits a mutation once and polls the same job, preserving errors', async () => {
  const id = randomUUID(), calls = [];
  const reply = await invoke('screenshot.capture', {}, { id, transport: async message => {
    calls.push(message);
    return { ok: true, launch_id: 'launch', job: { id, state: calls.length === 1 ? 'running' : 'failed', error: { code: 'PERMISSION_REQUIRED' } } };
  } });
  assert.deepEqual(calls.map(c => c.method), ['invoke', 'job']);
  assert.ok(calls.every(c => c.id === id));
  assert.equal(reply.job.error.code, 'PERMISSION_REQUIRED');
});

test('app restart and disconnect never replay a mutation', async () => {
  const calls = [];
  await assert.rejects(invoke('recording.start', {}, { transport: async message => {
    calls.push(message.method);
    return { ok: true, launch_id: calls.length === 1 ? 'first' : 'second', job: { state: 'running' } };
  } }), { code: 'APP_RESTARTED' });
  assert.deepEqual(calls, ['invoke', 'job']);
  let mutations = 0;
  await assert.rejects(invoke('note.create', { body: 'test' }, { transport: async () => { mutations++; throw new Error('disconnected'); } }));
  assert.equal(mutations, 1);
});

test('real Unix transport handles split replies and rejects unsafe socket permissions', async t => {
  const root = await mkdtemp(path.join(tmpdir(), 'man-ipc-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await chmod(root, 0o700);
  const socketPath = path.join(root, 'test.sock');
  const server = net.createServer(client => {
    client.once('data', data => {
      const input = JSON.parse(data); assert.equal(input.method, 'actions');
      client.write('{"ok":true,');
      setTimeout(() => client.end('"result":{"value":42}}\n'), 10);
    });
  });
  await new Promise((resolve, reject) => { server.on('error', reject); server.listen(socketPath, resolve); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  await chmod(socketPath, 0o600);
  const response = await request({ method: 'actions' }, { socketPath });
  assert.equal(response.result.value, 42);
  await chmod(socketPath, 0o666);
  await assert.rejects(request({ method: 'actions' }, { socketPath }), { code: 'INVALID_SOCKET' });
});
