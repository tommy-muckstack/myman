import { get, put, head, list, del } from '@vercel/blob';

async function readJSON(path) {
  const value = await get(path, { access: 'private', useCache: false });
  return value ? new Response(value.stream).json() : null;
}
const writeJSON = (path, value, overwrite = false) => put(path, JSON.stringify(value), { access: 'private', addRandomSuffix: false, allowOverwrite: overwrite, contentType: 'application/json' });
export const videoStore = {
  get: id => readJSON(`shares/${id}.json`),
  put: (id, value) => writeJSON(`shares/${id}.json`, value),
  ticket: id => readJSON(`video-tickets/${id}.json`),
  saveTicket: (id, value) => writeJSON(`video-tickets/${id}.json`, value),
  async events(id) {
    const items = await list({ prefix: `video-events/${id}/`, limit: 200 });
    return (await Promise.all(items.blobs.map(blob => readJSON(blob.pathname)))).filter(Boolean).sort((a, b) => a.createdAt - b.createdAt);
  },
  addEvent: (id, event) => writeJSON(`video-events/${id}/${event.id}.json`, event),
};
export const videoMedia = {
  async head(path) {
    try { return await head(path); }
    catch (error) { if (error?.constructor?.name === 'BlobNotFoundError') return null; throw error; }
  },
  async read(path, range) {
    const blob = await get(path, { access: 'private', useCache: false, ...(range ? { headers: { Range: range.header } } : {}) });
    if (!blob) return null;
    if (range && !blob.headers.get('content-range')?.startsWith(`bytes ${range.start}-${range.end}/`)) {
      await blob.stream.cancel(); throw new Error('Storage did not honor byte range');
    }
    return blob.stream;
  },
};
export async function cleanExpiredVideos(now = Date.now()) {
  let cursor, removed = 0;
  do {
    const page = await list({ prefix: 'video-tickets/', limit: 100, cursor });
    for (const blob of page.blobs) {
      const ticket = await readJSON(blob.pathname);
      const share = ticket && await videoStore.get(ticket.id);
      if (ticket && (ticket.expiresAt <= now || share?.revoked)) {
        await del(ticket.pathname);
        const events = await list({ prefix: `video-events/${ticket.id}/`, limit: 1000 });
        if (events.blobs.length) await del(events.blobs.map(event => event.pathname));
        if (share && !share.revoked) {
          await writeJSON(`shares/${ticket.id}.json`, { version: 2, id: ticket.id, revoked: true, expiresAt: ticket.expiresAt }, true);
        }
        // Keep the ticket/tombstone so an old client cannot resurrect the ID.
        removed++;
      }
    }
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return removed;
}
