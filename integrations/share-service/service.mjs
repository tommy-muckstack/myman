import { randomBytes, timingSafeEqual } from 'node:crypto';

export const MAX_BYTES = 3_000_000;
const idPattern = /^[a-zA-Z0-9_-]{32}$/;
const types = new Set(['text/html', 'text/plain', 'image/png']);
const headers = {
  'Cache-Control': 'private, no-store, max-age=0',
  'CDN-Cache-Control': 'no-store',
  'Vercel-CDN-Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'X-Robots-Tag': 'noindex, nofollow, noarchive',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "sandbox; default-src 'none'; img-src data:; media-src data:; font-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};
const response = (status, body, extra = {}) => ({ status, headers: { ...headers, ...extra }, body });
const json = (status, object) => response(status, JSON.stringify(object), { 'Content-Type': 'application/json' });
const authorized = (supplied, token) => {
  if (typeof token !== 'string' || token.length < 32 || typeof supplied !== 'string') return false;
  const a = Buffer.from(supplied), b = Buffer.from('Bearer ' + token);
  return a.length === b.length && timingSafeEqual(a, b);
};

// The adapter must perform uncached, consistent private reads. Never redirect
// to a blob URL: authorization and expiration are checked on every request.
export function createService({ store, publisherToken, now = () => Date.now() }) {
  return async ({ method, id, authorization, body }) => {
    if (['POST', 'DELETE'].includes(method) && !authorized(authorization, publisherToken)) return json(401, { error: 'Unauthorized' });
    if (method === 'POST' && !id) {
      if (!body || typeof body !== 'object' || typeof body.content !== 'string' || !types.has(body.mime_type) || !Number.isInteger(body.ttl_seconds) || body.ttl_seconds < 60 || body.ttl_seconds > 604800 || body.content.length > MAX_BYTES * 4 / 3 + 4 || !(/^[A-Za-z0-9+/]*={0,2}$/.test(body.content) && body.content.length % 4 === 0)) return json(400, { error: 'Invalid share: choose HTML, text or PNG, at most 3 MB, and expiration from 1 minute to 7 days.' });
      const bytes = Buffer.from(body.content, 'base64');
      if (!bytes.length || bytes.length > MAX_BYTES) return json(413, { error: 'Share too large or empty' });
      if (body.id !== undefined && !idPattern.test(body.id)) return json(400, { error: 'Invalid share ID' });
      const shareID = body.id ?? randomBytes(24).toString('base64url');
      const expiresAt = now() + body.ttl_seconds * 1000;
      await store.put(shareID, { version: 1, mime: body.mime_type, content: body.content, expiresAt, revoked: false });
      return json(201, { id: shareID, path: '/s/' + shareID, expires_at: new Date(expiresAt).toISOString() });
    }
    if (!idPattern.test(id ?? '')) return json(404, { error: 'Share unavailable' });
    if (method === 'DELETE') {
      // Tombstone first: an acknowledged revoke is consistently visible even
      // when a storage/CDN deletion would otherwise be eventually consistent.
      await store.put(id, { version: 1, revoked: true, expiresAt: 0 }, true);
      return json(200, { revoked: true });
    }
    if (method !== 'GET' && method !== 'HEAD') return json(405, { error: 'Method not allowed' });
    const value = await store.get(id);
    if (!value || value.revoked || !Number.isFinite(value.expiresAt) || value.expiresAt <= now() || !types.has(value.mime) || typeof value.content !== 'string') return json(410, { error: 'This share expired or was revoked.' });
    const bytes = Buffer.from(value.content, 'base64');
    if (bytes.length > MAX_BYTES) return json(410, { error: 'Share unavailable' });
    return response(200, method === 'HEAD' ? '' : bytes, { 'Content-Type': value.mime + (value.mime.startsWith('text/') ? '; charset=utf-8' : ''), 'Content-Length': String(bytes.length) });
  };
}
