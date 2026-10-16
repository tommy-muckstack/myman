import { Readable } from 'node:stream';
import { generateClientTokenFromReadWriteToken } from '@vercel/blob/client';
import { createVideoService } from '../video-service.mjs';
import { videoStore, videoMedia } from '../video-store.mjs';
export default async function handler(req, res) {
  try {
    let body = req.body;
    if (typeof body === 'string') { if (Buffer.byteLength(body) > 600_000) { res.status(413).end(); return; } body = JSON.parse(body); }
    const service = createVideoService({ store: videoStore, media: videoMedia, publisherToken: process.env.MYMAN_SHARE_PUBLISHER_TOKEN,
      issueToken: ticket => generateClientTokenFromReadWriteToken({ token: process.env.BLOB_READ_WRITE_TOKEN, pathname: ticket.pathname, maximumSizeInBytes: ticket.size, allowedContentTypes: [ticket.mime], addRandomSuffix: false, allowOverwrite: false, validUntil: Math.min(ticket.expiresAt, Date.now() + 3600_000) }) });
    const sameOrigin = req.headers.origin === `https://${req.headers.host}` && req.headers['x-myman-viewer'] === '1' && req.headers['content-type']?.startsWith('application/json');
    const result = await service({ method: req.method, id: req.query.id, action: req.query.action, authorization: req.headers.authorization, body, range: req.headers.range, sameOrigin });
    for (const [name, value] of Object.entries(result.headers)) res.setHeader(name, value);
    res.status(result.status);
    if (result.body instanceof ReadableStream) {
      const stream = Readable.fromWeb(result.body);
      res.on('close', () => stream.destroy()); stream.on('error', () => res.destroy()); stream.pipe(res);
    } else res.send(result.body);
  } catch {
    res.setHeader('Cache-Control', 'no-store');
    res.status(503).json({ error: 'The operation could not be confirmed. Retry using the same share ID.' });
  }
}
