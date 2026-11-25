import { handleSlackEvent } from '../slack-unfurl.mjs';
import { videoStore } from '../video-store.mjs';

// Slack signs the exact request bytes, so read the raw body rather than a parsed copy.
export const config = { api: { bodyParser: false } };

async function rawBody(req) {
  if (typeof req.body === 'string') return req.body;
  if (Buffer.isBuffer(req.body)) return req.body.toString('utf8');
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

export default async function handler(req, res) {
  try {
    const origin = process.env.SHARE_PUBLIC_ORIGIN;
    if (!origin) { res.status(503).end(); return; }
    const body = await rawBody(req);
    if (Buffer.byteLength(body) > 100_000) { res.status(413).end(); return; }
    const result = await handleSlackEvent({
      rawBody: body,
      timestamp: req.headers['x-slack-request-timestamp'],
      signature: req.headers['x-slack-signature'],
      signingSecret: process.env.SLACK_SIGNING_SECRET,
      botToken: process.env.SLACK_BOT_TOKEN,
      origin,
      store: videoStore,
    });
    if (result.json) { res.status(200).json(result.json); return; }
    res.status(result.status).end();
  } catch {
    res.status(500).end();
  }
}
