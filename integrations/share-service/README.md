# Optional My Man sharing

This personal publishing service serves selected screenshots, captured text, reviewed brief HTML, and person-published recordings. It uses a **private** Vercel Blob store and a dedicated publisher credential. It does not host the Brain or automatically upload captures. Each link is a bearer capability: anyone holding it can read the selected content until expiry or revocation. Previously downloaded copies cannot be recalled.

The native app records a pending share ID before sending. A timeout leaves an unconfirmed receipt that can be revoked; it never retries publication automatically. Agent publishing requires the separate `sharing` grant, a current source revision and `confirm=true`. A named agent can revoke only its own shares. Humans can revoke every share created by this Mac.

## Deploy your service

1. Deploy this directory as a Vercel project using Node 22.
2. Create and connect a **private** Blob store to the project. A public store is unsupported.
3. Set `MYMAN_SHARE_PUBLISHER_TOKEN` to a randomly generated secret of at least 32 characters in the production environment. Keep it out of source control and prompts.
4. Set `CRON_SECRET` to a separate random secret for the daily video cleanup route.
5. Deploy with `vercel --prod`. In My Man → Workflows → Sharing, enter the HTTPS origin and publishing credential. The credential is stored in the Mac's Keychain, separately for each service origin.
6. Publish a synthetic capture, inspect it, revoke it, and verify the copied URL returns HTTP 410.

The endpoint is intended for one person's publisher credential, not public anonymous upload. Do not embed the publisher credential in a redistributed app or browser client. Provision a separate project/credential for another publisher. Standard Vercel storage/function billing applies.

## Protocol

- `POST /api/shares`: publisher bearer authentication; JSON `{id?, content: base64, mime_type, ttl_seconds}`. The optional ID must be a random 32-character URL-safe value and is never overwritten. Returns ID, relative share path and server expiration.
- `GET` / `HEAD /s/:id`: serve only a current, unrevoked share. No Blob URL or storage credential is returned.
- `DELETE /api/shares?id=:id`: publisher authentication. Stores a payload-free revocation tombstone before acknowledging success.

Payload limit: 3 MB decoded. Types: PNG, plain text, inert HTML. Expiration: 60 seconds–7 days. Responses forbid browser/CDN caching, indexing and referrer forwarding. HTML is sandboxed without scripts, forms or external resources. Every read uses `get({access:'private',useCache:false})`; changing this invalidates immediate revocation guarantees. Storage/network errors fail closed. A request already in flight can finish during revocation; future requests are denied.

Expired payloads are inaccessible but remain in private storage until removed by the service operator. Revocation replaces the payload with a tombstone. Use the dedicated store's retention/cleanup process to remove old expired objects. This service does not promise remote deletion of a recipient's copies.

## Verification

`npm ci --ignore-scripts && npm test` checks expiry including HEAD, revocation, publisher authentication, input bounds, content isolation, cache headers and storage failure. The September 13, 2026 deployment additionally passed real publication, immediate revocation and timed expiry checks using synthetic content.

Consistent reads: https://vercel.com/changelog/vercel-blob-now-supports-consistent-reads-on-private-storage

## Private recordings

The native Sharing UI uploads MP4/MOV recordings up to 500 MiB directly to
private Blob storage with a short-lived, path-bound client token. Video bytes do
not pass through the JSON publication endpoint. The publisher credential stays
in Keychain; viewers receive neither storage URLs nor storage credentials.

- `POST /api/videos?id=:id&action=begin`: publisher authentication; exact byte
  size, MIME, SHA-256 fingerprint, title, TTL and optional `engagement` flag. An
  immutable ticket binds the ID to this source. Repeating it can discover an
  uploaded object after a lost response. Upload tokens never allow overwrite.
- `POST /api/videos?id=:id&action=complete`: publisher authentication; checks
  ticket and stored object metadata, accepts optional WebVTT captions, creates
  the share once. Completion and retry cannot overwrite a revocation tombstone.
- `GET /s/:id`: watch page with seeking, playback speed, captions and timestamp
  links. Optional comments/reactions are anonymous and limited to 200 per link.
- `GET` / `HEAD /api/videos?id=:id&action=media`: streams from private storage;
  supports one byte range and denies invalid ranges. Every new request checks
  expiry/revocation. Requests already in flight may finish.
- `GET /api/videos?id=:id&action=captions`: WebVTT with the same access checks.
- `GET` / `POST /api/videos?id=:id&action=events`: optional timestamped
  conversation. Browser writes require same-origin JSON and a viewer header.
- `DELETE /api/shares?id=:id`: existing authenticated revocation applies to
  watch pages, media, captions, comments and unfinished uploads.
- `GET /api/video-cleanup`: authenticated by `CRON_SECRET`; daily removal of
  expired/revoked video objects and events, with content-free share tombstones
  retained. Unfinished tickets are also cleaned after expiry.

The native app persists the ID before upload and exposes progress, cancellation,
retry and revocation. A retry reuses the same ID and exact source fingerprint.
A missing/corrupt local receipt store blocks new publication. Human recording
publication is separate from the existing agent recording-text share contract.

The service tests use synthetic stores/streams, including metadata for a 400 MiB
recording. They do **not** claim a real 400 MiB transfer or live Blob integration.
Before deploying this revision, verify client-token upload with the pinned SDK,
seeking/captions/comments in a browser, interrupted-upload retry, and 410 on all
read routes after expiry/revocation. See the repository's competitive-workflow
progress report for the current build and media verification limitations.
