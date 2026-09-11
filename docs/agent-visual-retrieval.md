# Visual capture retrieval

Agent feedback exposed a discovery gap: collection tools existed in the source
checkout but did not ship with the app/Brain. Work in this change:

- Bundle the existing CLI and stdio MCP companion into the app, export it under
  Brain/tools, and document it in README.md, AGENTS.md, and CLAUDE.md.
- Add one-call screenshots queries by meeting ID/path/description, app, range,
  tags, and near-duplicate sequence. Return ambiguous meetings as candidates.
- Export bidirectional screenshot/meeting links. Explicit links describe an
  active recording; historical associations use completed [start,end) intervals.
- Save the capture timezone; label historical local time as export_mac.
- Prefer prominent OCR regions over search-box text for automatic titles.
- Preserve source OCR as a YAML literal field, alongside a short description.
- Add heuristic content tags, PII/confidentiality hints, and visual similarity.
  These are not calibrated probabilities or authorization/security verdicts.
- Generate bounded 400px thumbnails off the capture path and expose explicit
  thumbnail image reads through the current catalog allowlist.
- Offer optional app/window/browser-document metadata for intentional region
  screenshots, with app exclusions. No activity polling or new permission prompt.
  URLs depend on existing Accessibility access and omit query/fragment/userinfo.

Migration v17 adds captureContext with cascading item ownership. Removing or
excluding captures removes context and current thumbnail exports; old Brain git
history and external backups retain their existing user-owned behavior.

Validated locally: 132 native tests (3 opt-in skips), 25 Node integration tests,
standalone bundled CLI/MCP without node_modules, native Swift export → bundled
CLI → 400px thumbnail, metadata settings rendering, skill validation, and bundle
freshness. Both Mac architectures are built before PR publication. CI gates
merging; the signed/notarized app update also includes conceptual Themes.
