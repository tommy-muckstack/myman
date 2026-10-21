import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

export const MAX_VIDEO_BYTES = 500 * 1024 * 1024;
const idPattern = /^[a-zA-Z0-9_-]{32}$/;
const noStore = { 'Cache-Control': 'private, no-store, max-age=0', 'CDN-Cache-Control': 'no-store', 'Vercel-CDN-Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Robots-Tag': 'noindex, nofollow, noarchive', 'Referrer-Policy': 'no-referrer' };
const reply = (status, value, extra = {}) => ({ status, headers: { ...noStore, 'Content-Type': 'application/json', ...extra }, body: typeof value === 'string' ? value : JSON.stringify(value) });
const auth = (provided, token) => {
  if (typeof token !== 'string' || token.length < 32 || typeof provided !== 'string') return false;
  const a = Buffer.from(provided), b = Buffer.from('Bearer ' + token);
  return a.length === b.length && timingSafeEqual(a, b);
};
const escape = text => String(text).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export function byteRange(header, size) {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) throw new Error('range');
  let start, end;
  if (!match[1]) { const suffix = Number(match[2]); if (!Number.isSafeInteger(suffix) || suffix <= 0) throw new Error('range'); start = Math.max(0, size - suffix); end = size - 1; }
  else { start = Number(match[1]); end = match[2] ? Math.min(size - 1, Number(match[2])) : size - 1; }
  if (![start, end].every(Number.isSafeInteger) || start < 0 || start > end || start >= size) throw new Error('range');
  return { start, end, header: `bytes=${start}-${end}` };
}

export function watchPage(id, value) {
  const nonce = randomBytes(18).toString('base64');
  const page = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escape(value.title)} · My Man</title>
  <style>@font-face{font-family:Gellix;src:url('/fonts/Gellix-Regular.ttf')}@font-face{font-family:Gellix;src:url('/fonts/Gellix-SemiBold.ttf');font-weight:600}:root{color-scheme:light dark;--background:#fff;--surface:#f9f9f9;--text:#1f1f26;--secondary:#737380;--border:#e6e6eb;--accent:#ffb84d}@media(prefers-color-scheme:dark){:root{--background:#141414;--surface:#1f1f1f;--text:#f5f5f5;--secondary:#b8b8b8;--border:#383838;--accent:#ffc766}}*{box-sizing:border-box}body{font:16px Gellix,sans-serif;max-width:1000px;margin:40px auto;padding:0 24px;background:var(--background);color:var(--text)}header{font-size:14px;color:var(--secondary);margin-bottom:24px}header strong{color:var(--text)}h1{font-size:30px;font-weight:600;letter-spacing:-.025em}h2{font-size:20px;font-weight:600;margin-top:32px}video{width:100%;max-height:75vh;background:#000;border-radius:12px;border:1px solid var(--border)}button,input,textarea,select{font:inherit;border:1px solid var(--border);border-radius:8px;background:var(--surface);color:var(--text);padding:10px;margin:6px 6px 6px 0;min-height:40px}button{cursor:pointer}button:hover{border-color:var(--accent)}button:focus-visible,input:focus-visible,textarea:focus-visible,select:focus-visible{outline:2px solid var(--accent);outline-offset:2px}textarea{display:block;width:100%;resize:vertical}small{color:var(--secondary);line-height:1.6}a{color:var(--text)}.comment{border-top:1px solid var(--border);padding:12px 0;overflow-wrap:anywhere}#status{color:var(--secondary)}@media(max-width:560px){body{margin:24px auto;padding:0 16px}h1{font-size:24px}}</style>
  <header><strong>My Man</strong> · Shared recording</header>
  <h1>${escape(value.title)}</h1><video id="video" controls preload="metadata" playsinline src="/api/videos?id=${id}&action=media">${value.captions ? `<track kind="captions" src="/api/videos?id=${id}&action=captions" srclang="und" label="Captions" default>` : ''}</video>
  <div><button id="timestamp">Copy link at this time</button><label>Speed <select id="speed"><option>0.75</option><option selected>1</option><option>1.25</option><option>1.5</option><option>2</option></select></label></div>
  <p><small>Available until ${escape(new Date(value.expiresAt).toISOString())}. Anyone holding this link can view it. Downloaded copies cannot be revoked.</small></p>
  ${value.engagement ? '<h2>Conversation</h2><label>Your name <input id="name" maxlength="80"></label><label>Comment at the current time<textarea id="comment" maxlength="2000"></textarea></label><button id="post">Post comment</button><button id="reaction">👍 React at this time</button><div id="events"></div>' : ''}<p id="status" role="status"></p>
  <script nonce="${nonce}">const video=document.getElementById('video'),status=document.getElementById('status');const seek=Number(new URL(location.href).hash.slice(3));if(location.hash.startsWith('#t=')&&Number.isFinite(seek)&&seek>=0)video.addEventListener('loadedmetadata',()=>{video.currentTime=Math.min(seek,video.duration)},{once:true});document.getElementById('speed').onchange=e=>video.playbackRate=Number(e.target.value);document.getElementById('timestamp').onclick=async()=>{try{const u=new URL(location.href);u.hash='t='+Math.floor(video.currentTime);history.replaceState(null,'',u);await navigator.clipboard.writeText(u.href);status.textContent='Timestamp link copied.'}catch{status.textContent='Copy the address after seeking to your time.'}};
  ${value.engagement ? `const endpoint='/api/videos?id=${id}&action=events';async function refresh(){const r=await fetch(endpoint,{cache:'no-store'});if(!r.ok)throw Error();const rows=await r.json();const box=document.getElementById('events');box.replaceChildren();for(const event of rows.events){const row=document.createElement('div');row.className='comment';const time=document.createElement('button');time.textContent=Math.floor(event.time)+'s';time.onclick=()=>{video.currentTime=event.time;video.play()};const text=document.createElement('span');text.textContent=event.name+': '+(event.reaction||event.text);row.append(time,text);box.append(row)}}async function post(reaction){try{const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json','X-MyMan-Viewer':'1'},body:JSON.stringify({name:document.getElementById('name').value||'Viewer',text:document.getElementById('comment').value,reaction,time:video.currentTime})});if(!r.ok)throw Error();document.getElementById('comment').value='';await refresh()}catch{status.textContent='Could not save. This link may have expired.'}}document.getElementById('post').onclick=()=>post(null);document.getElementById('reaction').onclick=()=>post('👍');refresh().catch(()=>status.textContent='Comments unavailable.');` : ''}</script></html>`;
  return reply(200, page, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; media-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` });
}

// Immutable tickets bind one publisher, ID, pathname and exact size. Completion
// is idempotent; it never accepts a client-supplied storage URL or overwrites a
// revocation tombstone. Private media is streamed, never redirected.
export function createVideoService({ store, publisherToken, issueToken, media, now = () => Date.now() }) {
  return async ({ method, id, action, authorization, body, range, sameOrigin = false }) => {
    if (!idPattern.test(id ?? '')) return reply(404, { error: 'Unknown recording' });
    const publisher = auth(authorization, publisherToken);
    const owner = createHash('sha256').update(publisherToken ?? '').digest('hex');
    if (['begin', 'complete'].includes(action) && (!publisher || method !== 'POST')) return reply(401, { error: 'Unauthorized' });
    if (action === 'begin') {
      if (!body || !Number.isSafeInteger(body.size) || body.size <= 0 || body.size > MAX_VIDEO_BYTES || !['video/mp4', 'video/quicktime'].includes(body.mime) || !Number.isInteger(body.ttl_seconds) || body.ttl_seconds < 60 || body.ttl_seconds > 604800 || typeof body.title !== 'string' || body.title.length > 300 || !/^[a-f0-9]{64}$/.test(body.fingerprint ?? '')) return reply(400, { error: 'Invalid recording metadata' });
      const existing = await store.get(id);
      if (existing?.revoked || existing && existing.expiresAt <= now()) return reply(410, { error: 'This share cannot be reused' });
      let ticket = await store.ticket(id);
      if (ticket && (ticket.owner !== owner || ticket.fingerprint !== body.fingerprint || ticket.size !== body.size || ticket.mime !== body.mime)) return reply(409, { error: 'The recording changed; start a new share' });
      if (!ticket) {
        ticket = { version: 2, id, owner, pathname: `videos/${id}.${body.mime === 'video/mp4' ? 'mp4' : 'mov'}`, fingerprint: body.fingerprint, size: body.size, mime: body.mime, title: body.title, engagement: body.engagement === true, expiresAt: now() + body.ttl_seconds * 1000 };
        await store.saveTicket(id, ticket); // create-only; races fail closed
      }
      if (ticket.expiresAt <= now()) return reply(410, { error: 'Upload expired' });
      if (existing?.version === 2) return reply(200, { id, published: true, expires_at: new Date(existing.expiresAt).toISOString() });
      // A retry can discover an already uploaded object after a lost response.
      const uploaded = await media.head(ticket.pathname);
      return reply(200, { id, pathname: ticket.pathname, uploaded: !!uploaded, clientToken: uploaded ? null : await issueToken(ticket), expires_at: new Date(ticket.expiresAt).toISOString() });
    }
    if (action === 'complete') {
      const existing = await store.get(id);
      if (existing?.revoked || existing && existing.expiresAt <= now()) return reply(410, { error: 'Share unavailable' });
      const ticket = await store.ticket(id);
      if (!ticket || ticket.owner !== owner || ticket.expiresAt <= now()) return reply(410, { error: 'Upload expired' });
      if (existing?.version === 2) return reply(200, { id, expires_at: new Date(existing.expiresAt).toISOString() });
      const blob = await media.head(ticket.pathname);
      if (!blob || blob.pathname !== ticket.pathname || blob.size !== ticket.size || blob.contentType !== ticket.mime) return reply(409, { error: 'Upload is incomplete or does not match its ticket' });
      const captions = typeof body?.captions === 'string' && body.captions.startsWith('WEBVTT\n') && Buffer.byteLength(body.captions) <= 500_000 ? body.captions : null;
      await store.put(id, { ...ticket, captions, revoked: false });
      return reply(201, { id, expires_at: new Date(ticket.expiresAt).toISOString() });
    }
    const value = await store.get(id);
    if (!value || value.version !== 2 || value.revoked || value.expiresAt <= now()) return reply(410, { error: 'This recording expired or was revoked' });
    if (action === 'events') {
      if (!value.engagement) return reply(403, { error: 'Comments are disabled' });
      if (method === 'GET') return reply(200, { events: await store.events(id) });
      if (method !== 'POST' || !sameOrigin) return reply(403, { error: 'Open the watch page to comment' });
      if (!body || typeof body.name !== 'string' || body.name.length > 80 || typeof body.text !== 'string' || body.text.length > 2000 || (!body.text.trim() && body.reaction !== '👍') || !Number.isFinite(body.time) || body.time < 0 || body.time > 86400 || body.reaction && body.reaction !== '👍') return reply(400, { error: 'Invalid comment' });
      const events = await store.events(id);
      if (events.length >= 200) return reply(429, { error: 'This conversation is full' });
      const event = { id: randomBytes(24).toString('base64url'), name: body.name || 'Viewer', text: body.text, reaction: body.reaction || null, time: body.time, createdAt: now() };
      await store.addEvent(id, event);
      return reply(201, { saved: true });
    }
    if (!['GET', 'HEAD'].includes(method)) return reply(405, { error: 'Method not allowed' });
    if (action === 'media') {
      let selected;
      try { selected = byteRange(range, value.size); } catch { return reply(416, '', { 'Content-Range': `bytes */${value.size}` }); }
      if (method === 'HEAD') return reply(selected ? 206 : 200, '', { 'Content-Type': value.mime, 'Content-Length': String(selected ? selected.end - selected.start + 1 : value.size), 'Accept-Ranges': 'bytes', ...(selected ? { 'Content-Range': `bytes ${selected.start}-${selected.end}/${value.size}` } : {}) });
      const stream = await media.read(value.pathname, selected);
      if (!stream) return reply(410, { error: 'Media unavailable' });
      return { status: selected ? 206 : 200, headers: { ...noStore, 'Content-Type': value.mime, 'Accept-Ranges': 'bytes', 'Content-Length': String(selected ? selected.end - selected.start + 1 : value.size), ...(selected ? { 'Content-Range': `bytes ${selected.start}-${selected.end}/${value.size}` } : {}) }, body: stream };
    }
    if (action === 'captions') return reply(200, method === 'HEAD' ? '' : value.captions ?? 'WEBVTT\n\n', { 'Content-Type': 'text/vtt; charset=utf-8' });
    const page = watchPage(id, value); if (method === 'HEAD') page.body = ''; return page;
  };
}
