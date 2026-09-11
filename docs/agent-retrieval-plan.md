# Agent access to MyMan information

Agents need general evidence collection, rather than a bespoke endpoint for
every natural-language request. MyMan remains a utility the human invokes.
The requesting agent interprets the request and analyzes returned evidence;
the companion supplies deterministic, read-only local retrieval.

## Architecture audit

- `Brain.swift` already exports notes, meetings, screenshot OCR and image paths,
  recordings, people, vocabulary, and a capped task checklist to `~/MyManBrain`.
- `integrations/brain` already provides one shared implementation for local CLI
  and stdio MCP. It validates export paths and returns citations. Legacy search
  returns at most 50 results and lacks time filtering.
- `captureItem` already unifies intentional captures, title precedence, times,
  pinning, and search exclusion. `captureTheme`/`captureThemeMember` already own
  saved Themes and corrections. These remain authoritative.
- Meeting exports contain start/end times and participant labels. Screenshot
  exports contain original capture timestamps, independent of OCR availability.
- Dictation, saved Themes, task notes/dates, and uncapped task history were absent
  from the agent interface. Native semantic search exists in the app; the Node
  companion does not have an embedding runtime.

## Implementation

1. Add general `collect`: multiple types, half-open date ranges, participant
   identities, keywords/quoted phrases, all/any matching, saved Theme ID/name,
   pinning, and task state. Expose totals, pagination, coverage, and citations.
2. Use `meetings` to resolve a particular call and `during` to collect any capture
   types from its full recorded interval. Keep `meeting_screenshots` as a thin
   user-facing convenience with chronological results. No name is hard-coded.
3. Extend Brain exports from the existing data models. A debounced observer
   snapshots committed source data, releases the database read, then formats
   exports on Brain's background queue. Content hashes avoid rewriting unchanged
   documents. There is no new database table, embedding store, or cloud service.
4. Add a versioned atomic metadata catalog, complete individual task exports,
   dictation exports, and saved Theme documents with source paths. Respect search
   exclusion, dismissed Themes, blocked memberships, and archived tasks.
5. Read original PNG screenshots only through explicit `image` calls using
   catalog-listed paths. Return images over MCP for visual descriptors that OCR
   cannot answer. Retain byte/pixel bounds and file/symlink checks.
6. Teach agents to paginate and read full evidence before comprehensive claims,
   distinguish saved Themes from their own synthesis, resolve ambiguous singular
   calls, and report incomplete/legacy coverage.

## Validation

- Native fixtures cover 135 tasks (35 open), complete task notes, dictation,
  participant names and meeting bounds, pinning, Theme membership/corrections,
  exclusion, and deletion. No personal capture data enters the fixtures.
- Node tests cover collection filters, phrases/synonyms, pagination beyond 50
  screenshots, offset timezones and midnight, exact boundaries, missing dates,
  missing/changed exports, catalog allowlisting, and original image reads.
- The official MCP client exercises discovery, collection, meeting relationships,
  evidence reads, actual PNG image content, and safe errors over stdio.
- Run the full native suite, debug compilation, universal release build, Node
  suite, and skill validation before publishing.

## Limits made explicit

Retrieval is lexical; descriptor interpretation and thematic synthesis belong to
the agent. Media queries inspect screenshots explicitly rather than infer image
content from OCR. Time overlap indicates when a capture happened, not necessarily
what it concerns. Unknown dates/end times are never replaced with file mtimes.
The catalog is an export snapshot; readers detect revisions changing during scans
and expose snapshot IDs for pagination. Legacy folders retain their limited
coverage until the updated app exports a catalog. Existing user-owned Brain git
history is preserved and is not a secure erase mechanism. There is no remote
connector, automatic upload, or autonomous action runner.
