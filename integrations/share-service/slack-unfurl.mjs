import { createHmac, timingSafeEqual } from 'node:crypto';

// Slack's link unfurling for shared recordings. A link_shared event for one of our share links gets a
// Block Kit video block, so the recording plays inside Slack. Only links on our own origin, to shares that
// are current and have a poster, are unfurled. Anything else is ignored.

export const MAX_SKEW_SECONDS = 300;

/** v0 signature: HMAC-SHA256 of "v0:<timestamp>:<raw body>" with the signing secret. Rejects stale timestamps. */
export function verifySlackSignature({ signingSecret, timestamp, signature, rawBody, now = Date.now() }) {
  if (!signingSecret || !timestamp || !signature) return false;
  const seconds = Number(timestamp);
  if (!Number.isInteger(seconds) || Math.abs(now / 1000 - seconds) > MAX_SKEW_SECONDS) return false;
  const expected = 'v0=' + createHmac('sha256', signingSecret).update(`v0:${timestamp}:${rawBody}`).digest('hex');
  const a = Buffer.from(expected), b = Buffer.from(String(signature));
  return a.length === b.length && timingSafeEqual(a, b);
}

/** The share ID when a link is one of our share pages on our origin; otherwise null. */
export function shareIdFromLink(link, origin) {
  try {
    const url = new URL(link), expected = new URL(origin);
    if (url.origin !== expected.origin) return null;
    const match = /^\/s\/([a-zA-Z0-9_-]{32})$/.exec(url.pathname);
    return match ? match[1] : null;
  } catch { return null; }
}

/** The video block for one share, or null when the share has no poster (Slack needs a thumbnail). */
export function videoBlock(id, value, origin) {
  if (!value.poster) return null;
  const title = String(value.title || 'Shared recording').slice(0, 200);
  const minutes = value.duration_ms ? `${Math.max(1, Math.round(value.duration_ms / 60000))} min` : null;
  const description = [minutes, value.chapters?.length ? `${value.chapters.length} chapters` : null].filter(Boolean).join(' · ') || 'Shared with My Man';
  return {
    type: 'video',
    alt_text: `Shared recording: ${title}`,
    title: { type: 'plain_text', text: title },
    description: { type: 'plain_text', text: description.slice(0, 200) },
    title_url: `${origin}/s/${id}`,
    video_url: `${origin}/api/videos?id=${id}&action=embed`,
    thumbnail_url: `${origin}/api/videos?id=${id}&action=poster`,
    provider_name: 'My Man',
  };
}

/**
 * Handles one Slack request. Returns { status, json? }.
 * Deps: store (videoStore), botToken, fetchImpl, now.
 */
export async function handleSlackEvent({ rawBody, timestamp, signature, signingSecret, botToken, origin, store, now = Date.now(), fetchImpl = fetch }) {
  if (!verifySlackSignature({ signingSecret, timestamp, signature, rawBody, now })) return { status: 401 };
  let payload;
  try { payload = JSON.parse(rawBody); } catch { return { status: 400 }; }
  if (payload.type === 'url_verification') return { status: 200, json: { challenge: payload.challenge } };
  if (payload.type !== 'event_callback' || payload.event?.type !== 'link_shared') return { status: 200 };

  const unfurls = {};
  for (const link of payload.event.links ?? []) {
    const id = shareIdFromLink(link?.url, origin);
    if (!id) continue;
    const value = await store.get(id);
    if (!value || value.version !== 2 || value.revoked || !(value.expiresAt > now)) continue;
    const block = videoBlock(id, value, origin);
    if (block) unfurls[link.url] = { blocks: [block] };
  }
  if (Object.keys(unfurls).length === 0) return { status: 200 };

  // Composer links are unfurled by unfurl_id + source; links in a message by channel + ts.
  const event = payload.event;
  const params = new URLSearchParams({ unfurls: JSON.stringify(unfurls) });
  if (event.source === 'composer') { params.set('unfurl_id', event.unfurl_id); params.set('source', 'composer'); }
  else { params.set('channel', event.channel); params.set('ts', event.message_ts); }
  const response = await fetchImpl('https://slack.com/api/chat.unfurl', {
    method: 'POST',
    headers: { Authorization: `Bearer ${botToken}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params,
  });
  const data = await response.json().catch(() => ({}));
  return data.ok ? { status: 200 } : { status: 502 };
}
