# MyMan Brain plugin implementation plan

## Outcome

Let an agent answer questions from MyMan's exported meetings, notes, tasks,
people, screenshot OCR, and recording transcripts, with file and line citations.
Ship a local, read-only integration first. The native app's database, capture
controllers, permissions, and on-device AI remain outside the integration.

## Architecture and decisions

1. Add a standalone Node.js companion under `integrations/brain/`. Share one
   bounded file reader and query layer between a JSON command-line interface
   and an MCP stdio server using the official SDK. Node is an explicit setup
   prerequisite; no new runtime or dependencies enter the Swift app.
2. Read only the known Brain export locations. Do not follow symlinks, traverse
   outside the configured Brain root, read media paths from frontmatter, or
   open SQLite. Restrict file sizes, result counts, and document page sizes.
   Report missing roots and partial scans distinctly from zero results.
3. Expose status, keyword search, recent documents/meetings, paginated document
   reads, and paginated task lists. Include source-relative paths, line ranges,
   timestamps when present, and low-content transcript flags. Use deterministic
   keyword ranking; do not call an embedding service or claim semantic search.
4. Package a root Agent Plugins manifest, local MCP configuration, and a skill
   explaining source quality, citations, pagination, and one-way export sync.
   Document installation and the Grok Bot local-command route separately.
5. Test against synthetic Brain folders, including malformed files, traversal,
   symlinks, empty/missing exports, changing exports, large documents, task
   pagination, CLI behavior, and real SDK client/server tool calls. Add a CI job.

## Grok Bot boundary

Grok Bot normally works on a cloud computer. Its desktop local-execution
capability is documented, but Cursor IDE local MCP/plugin support is not proof
of Grok Bot local MCP support. The first Grok route runs the companion CLI on
the Mac using that capability. Setup must use the absolute checkout path on
that Mac. A cloud-only installation cannot access `~/MyManBrain` on a Mac.

The companion makes no network requests and starts no HTTP listener. Passing
results to Grok or another hosted model shares those selected results with
that provider. This is an explicit optional integration, not on-device Grok.
An unattended remote connector would require separate authenticated transport
and distribution design; it is not silently added to this release.

## Acceptance and release

- CLI and MCP return matching grounded results without modifying fixture files.
- MCP initializes and discovers tools through the official SDK client.
- Bad paths and linked files cannot expose files outside the export surface.
- README provides executable setup commands and an explicit smoke-test prompt.
- Plugin manifests and skill frontmatter validate; clean installs pass tests.
- Live Grok Bot execution and marketplace acceptance are reported separately
  from automated verification. Do not mark them passed without exercising them.
- After validation, publish the public repository changes and submit its URL
  for marketplace review when publishing is authorized. No signing, notarizing,
  release-feed changes, or analytics changes are needed for this companion.

## References checked September 11, 2026

- https://agent-plugins.org/plugin-authors/manifest
- https://agent-plugins.org/plugin-authors/mcp-servers
- https://cursor.com/docs/plugins
- https://cursor.com/docs/grok-bot/work
- https://cursor.com/docs/grok-bot/settings
- https://cursor.com/marketplace/publish
- https://github.com/modelcontextprotocol/typescript-sdk

## Implementation and verification record

Implemented the shared bounded reader, five tools, JSON CLI, stdio MCP server,
root plugin manifests, packaged skill, setup guide, locked dependencies, and
macOS CI job. The official MCP SDK 2.0.0 handles protocol negotiation and tool
dispatch; no custom JSON-RPC implementation is maintained here.

Verified a clean offline dependency install from the generated lockfile and
13 automated tests, including a real SDK client launching the server. Both
root manifests validated against the official Agent Plugins 1.0.0 JSON
schemas. The tests use synthetic temporary files, including Unicode, long
transcript lines, malformed UTF-8, and unsafe paths.

The packaged skill passed the skill validator. A separate local status check
recognized the existing MyManBrain exports with no warnings or partial scan;
that check returned counts only, not document contents.

Native Swift code and build configuration were not changed; native builds
were not needed for this separately installed companion. Live Grok Bot
execution and marketplace submission remain unverified/unpublished. The
setup guide provides the target-client smoke test and explains that boundary.
