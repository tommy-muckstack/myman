# Local screenshot fonts

The native screenshot action uses the editor’s underlying image, including
pixel edits/crops, at original resolution. Decorative backgrounds, annotations
and translation overlays are deliberately excluded from recognition.

The workbench bundles the active raster/metrics/sample-ranking/tracing/font
writer and matching engine from `/Users/tommykeeley/fontscope`, inspected on
`main` at `d2098420570ead28ee741b043cf3e7bb7ae7ceb4` with a clean working tree.
The original source checkout is not modified. No historical remote-fill,
OpenCV/Potrace, blind-mirroring completion, or Next.js shell is included.

Apple Vision supplies actual character geometry through a bounded native
bridge. A local WKWebView runs the bundled outline engine, with HTTP(S) blocked.
It needs neither Node nor a development server, external OCR downloads, or API
credentials. Bundled font notices accompany the matching/fallback assets.

Missing-character construction measures captured outlines and adapts a local
anatomical skeleton for each target. Provenance and weak evidence are visible;
matching and optional external-font fallback remain separate from inference.
The preview uses exactly the generated OpenType CFF (`OTTO`, `.otf`) bytes.

Saved font projects reuse notes and document-owned assets, making names, source
text, matches and provenance searchable without a separate toolbar section.
Deleting the note uses the existing document-asset cleanup lifecycle.

Development: `npm ci`, `npm test`, `npm run typecheck`, `npm run bundle`.
This integration is local and unreleased pending the user’s separate release
instruction. The existing 1.1.58 release does not contain it.
