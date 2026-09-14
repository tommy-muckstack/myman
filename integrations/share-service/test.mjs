import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createService, MAX_BYTES } from './service.mjs';
const token = 'synthetic-publisher-token-for-tests-only';
function fixture() {
  const values = new Map(); let clock = 100000;
  const service = createService({ publisherToken: token, now: () => clock, store: { get: async id => values.get(id), put: async (id, v) => values.set(id, v) } });
  const publish = body => service({ method: 'POST', authorization: 'Bearer ' + token, body: { content: Buffer.from('Synthetic capture').toString('base64'), mime_type: 'text/plain', ttl_seconds: 60, ...body } });
  return { service, publish, advance: ms => clock += ms, values };
}
test('server enforces expiry for both GET and HEAD, including copied paths', async () => {
  const { service, publish, advance } = fixture();
  const created = await publish(); assert.equal(created.status, 201); const { id } = JSON.parse(created.body);
  assert.equal((await service({ method: 'GET', id })).body.toString(), 'Synthetic capture');
  advance(60000);
  assert.equal((await service({ method: 'GET', id })).status, 410);
  assert.equal((await service({ method: 'HEAD', id })).status, 410);
});
test('revocation removes payload and prevents subsequent delivery', async () => {
  const { service, publish, values } = fixture(); const { id } = JSON.parse((await publish()).body);
  assert.equal((await service({ method: 'DELETE', id })).status, 401);
  assert.equal((await service({ method: 'DELETE', id, authorization: 'Bearer ' + token })).status, 200);
  assert.equal(values.get(id).content, undefined);
  assert.equal((await service({ method: 'GET', id })).status, 410);
});
test('untrusted content is isolated and cannot be CDN cached', async () => {
  const { service, publish } = fixture(); const { id } = JSON.parse((await publish({ mime_type: 'text/html', content: Buffer.from('<script>alert(1)</script>').toString('base64') })).body);
  const value = await service({ method: 'GET', id });
  assert.match(value.headers['Content-Security-Policy'], /^sandbox;/);
  assert.equal(value.headers['Vercel-CDN-Cache-Control'], 'no-store');
  assert.equal(value.headers['Referrer-Policy'], 'no-referrer');
});
test('publication requires authentication and bounds type, lifetime and content', async () => {
  const { service, publish } = fixture();
  assert.equal((await service({ method: 'POST', body: {} })).status, 401);
  for (const args of [{ ttl_seconds: 0 }, { ttl_seconds: 604801 }, { mime_type: 'application/javascript' }, { content: 'malformed!' }, { content: Buffer.alloc(MAX_BYTES + 1).toString('base64') }]) assert.ok((await publish(args)).status >= 400);
  assert.equal((await service({ method: 'GET', id: '../../secret' })).status, 404);
});
test('storage failure never acknowledges publication or revocation', async () => {
  const service = createService({ publisherToken: token, store: { put: async () => { throw new Error('offline'); } } });
  await assert.rejects(service({ method: 'DELETE', id: 'a'.repeat(32), authorization: 'Bearer ' + token }));
});
