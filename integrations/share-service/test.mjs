import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createService, MAX_BYTES } from './service.mjs';
import { createVideoService, byteRange, MAX_VIDEO_BYTES, watchPage } from './video-service.mjs';
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

function videoFixture() {
  const shares = new Map(), tickets = new Map(), blobs = new Map(), events = new Map(); let clock = 100000;
  const store = {
    get: async id => shares.get(id),
    put: async (id, value, overwrite = false) => { if (!overwrite && shares.has(id)) throw Error('exists'); shares.set(id, value); },
    ticket: async id => tickets.get(id),
    saveTicket: async (id, value) => { if (tickets.has(id)) throw Error('exists'); tickets.set(id, value); },
    events: async id => events.get(id) ?? [],
    addEvent: async (id, event) => events.set(id, [...events.get(id) ?? [], event]),
  };
  const reads = [];
  const media = { head: async path => blobs.get(path), read: async (path, range) => { reads.push({ path, range }); return Buffer.from('synthetic media'); } };
  const service = createVideoService({ store, media, publisherToken: token, now: () => clock, issueToken: async ticket => 'bound-to:' + ticket.pathname });
  const id = 'v'.repeat(32);
  const body = { size: 400 * 1024 * 1024, mime: 'video/mp4', title: 'Synthetic demo', fingerprint: 'a'.repeat(64), ttl_seconds: 60 };
  const call = (action, extra = {}) => service({ method: 'POST', action, id, authorization: 'Bearer ' + token, body, ...extra });
  const upload = () => blobs.set(`videos/${id}.mp4`, { pathname: `videos/${id}.mp4`, size: body.size, contentType: body.mime });
  return { service, call, upload, body, id, shares, tickets, blobs, reads, store, advance: ms => clock += ms };
}

test('large direct upload binds path and size, completes idempotently, and never exposes a media URL', async () => {
  const f = videoFixture(); const grant = await f.call('begin');
  assert.equal(grant.status, 200); assert.match(JSON.parse(grant.body).clientToken, /^bound-to:videos\//);
  assert.equal((await f.call('complete')).status, 409);
  f.upload(); const done = await f.call('complete'); assert.equal(done.status, 201);
  assert.equal((await f.call('complete')).status, 200);
  assert.equal(f.shares.size, 1);
  const page = await f.service({ method: 'GET', id: f.id });
  assert.equal(page.status, 200); assert.match(page.body, /<video /); assert.doesNotMatch(page.body, /blob\.vercel/);
  const range = await f.service({ method: 'GET', id: f.id, action: 'media', range: 'bytes=100-199' });
  assert.equal(range.status, 206); assert.equal(range.headers['Content-Length'], '100');
  assert.equal(f.reads[0].range.header, 'bytes=100-199');
});

test('upload retries cannot replace content or revive revoked IDs', async () => {
  const f = videoFixture(); await f.call('begin'); f.upload();
  assert.equal(JSON.parse((await f.call('begin')).body).uploaded, true);
  assert.equal((await f.call('begin', { body: { ...f.body, fingerprint: 'b'.repeat(64) } })).status, 409);
  const revoke = createService({ store: f.store, publisherToken: token });
  await revoke({ method: 'DELETE', id: f.id, authorization: 'Bearer ' + token });
  assert.equal((await f.call('complete')).status, 410);
  assert.equal((await f.call('begin')).status, 410);
  for (const method of ['GET', 'HEAD']) {
    assert.equal((await f.service({ method, id: f.id, action: 'media', range: 'bytes=0-99' })).status, 410);
  }
  assert.equal(f.reads.length, 0);
});

test('expiration applies to playback, subtitles and comments on every request', async () => {
  const f = videoFixture(); await f.call('begin', { body: { ...f.body, engagement: true } }); f.upload(); await f.call('complete'); f.advance(60000);
  for (const action of ['media', 'captions', 'events', undefined]) {
    assert.equal((await f.service({ method: 'GET', id: f.id, action })).status, 410);
  }
});

test('mismatched metadata and unauthorized upload grants fail closed', async () => {
  const f = videoFixture();
  assert.equal((await f.call('begin', { authorization: '' })).status, 401);
  assert.equal((await f.call('begin', { body: { ...f.body, size: MAX_VIDEO_BYTES + 1 } })).status, 400);
  await f.call('begin'); f.upload(); f.blobs.get(`videos/${f.id}.mp4`).size--;
  assert.equal((await f.call('complete')).status, 409);
  assert.equal(f.shares.size, 0);
});

test('range requests validate bounds and watch content is escaped', () => {
  assert.deepEqual(byteRange('bytes=-5', 20), { start: 15, end: 19, header: 'bytes=15-19' });
  assert.deepEqual(byteRange('bytes=3-', 20), { start: 3, end: 19, header: 'bytes=3-19' });
  for (const range of ['bytes=20-', 'bytes=7-3', 'bytes=-0', 'bytes=0-1,2-3', 'bytes=NaN-4']) assert.throws(() => byteRange(range, 20));
  const page = watchPage('a'.repeat(32), { title: '</title><script>alert(1)</script>', expiresAt: 100000 });
  assert.doesNotMatch(page.body, /<script>alert/); assert.match(page.headers['Content-Security-Policy'], /script-src 'nonce-/);
});

test('comments require same-origin intent and are stored as text', async () => {
  const f = videoFixture(); await f.call('begin', { body: { ...f.body, engagement: true } }); f.upload(); await f.call('complete');
  const event = { name: 'Synthetic reviewer', text: '<img src=x onerror=alert(1)>', time: 12.5 };
  assert.equal((await f.call('events', { body: event })).status, 403);
  assert.equal((await f.call('events', { body: event, sameOrigin: true })).status, 201);
  const result = await f.service({ method: 'GET', id: f.id, action: 'events' });
  assert.equal(JSON.parse(result.body).events[0].text, event.text);
  const page = await f.service({ method: 'GET', id: f.id }); assert.match(page.body, /text\.textContent=/);
});
