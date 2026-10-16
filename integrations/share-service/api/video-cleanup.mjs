import { timingSafeEqual } from 'node:crypto';
import { cleanExpiredVideos } from '../video-store.mjs';
export default async function handler(req, res) {
  const secret = process.env.CRON_SECRET;
  const a = Buffer.from(req.headers.authorization ?? ''), b = Buffer.from('Bearer ' + (secret ?? ''));
  res.setHeader('Cache-Control', 'no-store');
  if (!secret || a.length !== b.length || !timingSafeEqual(a, b)) return res.status(401).end();
  try { res.json({ removed: await cleanExpiredVideos() }); }
  catch { res.status(503).json({ error: 'Cleanup incomplete; retry on the next run' }); }
}
