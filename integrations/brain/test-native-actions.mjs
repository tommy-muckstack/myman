// Opt-in: run only against scripts/package-local.py's isolated verification app.
import assert from 'node:assert/strict';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { invoke, request } from './actions.mjs';
const root = process.argv[2];
assert.ok(root?.startsWith('/private/tmp/man-verification-'));
const ready = JSON.parse(await readFile(root + '/ready.json'));
assert.equal(ready.root, root);
assert.equal(ready.socket,root+'/IPC/control.sock');
process.env.MYMAN_AGENT_SOCKET=ready.socket;
const results = [];
async function run(action, args = {}, options = {}) {
  const reply = await invoke(action, args, options);
  assert.equal(reply.job.state, 'succeeded', JSON.stringify(reply));
  results.push({ action, result: reply.job.result });
  return reply.job.result;
}
const status = await run('app.status');
assert.equal(status.version, '1.1.60-preview');
const note = await run('note.create', { body: '# CLI fixture\nOriginal note body.' });
const read = await run('item.read', { id: note.id });
await run('note.update', { id: note.id, body: '# CLI fixture\nUpdated body.', expected_updated_at: read.updated_at });
const conflict = await invoke('note.update', { id: note.id, body: 'Must not overwrite', expected_updated_at: read.updated_at });
assert.equal(conflict.job.error.code, 'EDIT_CONFLICT');
const imported = await run('screenshot.import', { path: ready.fixture });
const edited = await run('screenshot.edit', { id: imported.id, annotations: [{ type: 'box', rect: [30,200,700,280] }, { type: 'text', rect: [35,30,300,70], text: 'Verified by CLI' }], clipboard: true });
assert.notEqual(edited.id, imported.id);
assert.notEqual(edited.path, imported.path);
assert.ok((await stat(edited.path)).size > 1000);
const clipboard = await run('clipboard.read', { format: 'image' });
assert.equal(clipboard.image.mimeType, 'image/png');
await writeFile(root + '/clipboard.png', Buffer.from(clipboard.image.data, 'base64'));
// Avoid retaining image base64 in the report.
results.at(-1).result = { image: 'clipboard.png' };
const ocr = await run('screenshot.ocr', { id: imported.id });
assert.match(ocr.text, /verification/i); assert.ok(ocr.regions.length > 0);
const requestID = randomUUID();
const once = await run('note.create', { body: 'Idempotency fixture' }, { id: requestID });
const twice = await run('note.create', { body: 'Idempotency fixture' }, { id: requestID });
assert.equal(once.id, twice.id);
const wrongSession = await invoke('recording.stop', { session_id: randomUUID() });
assert.equal(wrongSession.job.error.code, 'SESSION_MISMATCH');
if (status.permissions.screen_recording) {
  await run('screenshot.capture', { region: ready.region });
  const recording = await run('recording.start', { region: ready.region, microphone: false });
  await new Promise(resolve => setTimeout(resolve, 2200));
  const movie = await run('recording.stop', { session_id: recording.session_id });
  assert.ok((await stat(movie.path)).size > 1000);
  await run('item.read', { id: movie.id });
}
const font = await run('font.create', { id: imported.id, name: 'Agent font fixture' });
const fontFile = await readFile(font.path); assert.equal(fontFile.subarray(0,4).toString(), 'OTTO');
await run('font.file', { id: font.id });
await run('item.read', { id: font.id });
await run('item.delete', { id: note.id, confirm: true });
await run('item.delete', { id: once.id });
await writeFile(root + '/report.json', JSON.stringify({ passed: true, results }, null, 2));
console.log(JSON.stringify({ passed: true, actions: results.map(r => r.action), report: root + '/report.json' }));
