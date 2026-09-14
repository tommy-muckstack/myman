# Optional My Man sharing

This personal publishing service serves selected screenshots, captured text and reviewed brief HTML. It uses a **private** Vercel Blob store and a dedicated publisher credential. It does not host the Brain or automatically upload captures. Each link is a bearer capability: anyone holding it can read the selected content until expiry or revocation. Previously downloaded copies cannot be recalled.

The native app records a pending share ID before sending. A timeout leaves an unconfirmed receipt that can be revoked; it never retries publication automatically. Agent publishing requires the separate `sharing` grant, a current source revision and `confirm=true`. A named agent can revoke only its own shares. Humans can revoke every share created by this Mac.

## Deploy your service

1. Deploy this directory as a Vercel project using Node 22.
2. Create and connect a **private** Blob store to the project. A public store is unsupported.
3. Set `MYMAN_SHARE_PUBLISHER_TOKEN` to a randomly generated secret of at least 32 characters in the production environment. Keep it out of source control and prompts.
4. Deploy with `vercel --prod`. In My Man → Workflows → Sharing, enter the HTTPS origin and publishing credential. The credential is stored in the Mac's Keychain, separately for each service origin.
5. Publish a synthetic capture, inspect it, revoke it, and verify the copied URL returns HTTP 410.

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
