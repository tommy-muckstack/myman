import { get, put } from '@vercel/blob';
import { createService } from '../service.mjs';
const store = {
  async get(id) {
    const blob = await get(`shares/${id}.json`, { access: 'private', useCache: false });
    if (!blob) return null;
    return new Response(blob.stream).json();
  },
  async put(id, value, overwrite = false) {
    await put(`shares/${id}.json`, JSON.stringify(value), { access: 'private', addRandomSuffix: false, allowOverwrite: overwrite, contentType: 'application/json' });
  },
};
export default async function handler(req, res) {
  try {
    let body = req.body;
    if (typeof body === 'string') { if (Buffer.byteLength(body) > 4_100_000) { res.status(413).end(); return; } body = JSON.parse(body); }
    const service = createService({ store, publisherToken: process.env.MYMAN_SHARE_PUBLISHER_TOKEN });
    const result = await service({ method: req.method, id: req.query.id, authorization: req.headers.authorization, body });
    for (const [name, value] of Object.entries(result.headers)) res.setHeader(name, value);
    res.status(result.status).send(result.body);
  } catch {
    res.setHeader('Cache-Control', 'no-store');
    res.status(503).json({ error: 'Sharing is temporarily unavailable. No successful publication or revocation is claimed.' });
  }
}
