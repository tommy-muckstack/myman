# Resolve saved people

`people.resolve` maps names to email addresses already saved in MyMan. It never invents an address, reads Contacts or a live calendar, enrolls a person, sends an invitation or books an event. It is the third scheduling primitive; the scheduling preview and Book flow are separate work.

```sh
myman people resolve --names '["jilles","harshil"]' --json
myman people resolve --names '["Developer","Sam"]' --limit 3 --json
myman invoke people.resolve '{"names":["jilles@example.test"]}' --json
myman actions people.resolve --json
```

The matching MCP tool is `myman_app_people_resolve`, with the same `names` array and optional `limit`. The canonical schema is `integrations/brain/actions.json`. Supply 1–20 nonblank names or exact email addresses, at most 200 UTF-16 code units each, without control characters. `limit` is 1–10 candidates per name (default 5). Input order and repeated inputs are preserved.

Example payload inside the normal success envelope:

```json
{
  "results": [
    {
      "input": "jilles",
      "status": "resolved",
      "candidates": [{
        "name": "Jilles Smith",
        "email": "jilles@example.test",
        "sources": ["people"],
        "match": "name_tokens"
      }],
      "total": 1,
      "truncated": false
    }
  ],
  "source": "local_people",
  "contacts_accessed": false,
  "side_effects": false
}
```

| Status | Meaning |
| --- | --- |
| `resolved` | Exactly one identity matched an email, full name or whole name tokens, with a stored usable email. This is lookup evidence, not authority to book or invite. |
| `ambiguous` | More than one identity matched. Present the candidates for human selection; never pick the first automatically. |
| `missing_email` | One identity matched, but no supported email is saved. The candidate omits `email`. Ask the person for the address; do not synthesize it from a name/domain. |
| `needs_confirmation` | One email-bearing identity matched only a name prefix. Human confirmation is required. |
| `not_found` | No saved match. An unrecognized address supplied by the caller is not treated as a known identity. |

Names are normalized with Unicode compatibility decomposition, accent removal, lowercase and letter/number token boundaries. Matching considers exact email, exact name, consecutive whole name tokens, then token-start prefixes of at least two characters. No typo correction or model-based identity inference is used. All matching identities count toward ambiguity before applying the output limit; `total` and `truncated` report omitted candidates.

Records sharing a normalized email merge their name aliases and source labels. The fullest saved alias is displayed, with deterministic lexical tie-breaking. Different addresses remain separate even when names are identical. A name-only row is not silently attached to an email-bearing row. Email syntax is conservative ASCII; unsupported/malformed addresses remain unresolved as `missing_email`. Generic labels such as You, Others and Speaker 2 are excluded. Matching never ranks people by private meeting frequency or recency.

## Permissions and data sources

The new `people_read` grant starts off. On Mac the human enables **Resolve saved people and emails** in Settings → Agents, plus local app commands. Named credentials also need the `people_read` scope; existing credentials receive no automatic scope expansion. On Linux the human adds `people_read: true` to the existing private `agents.json`, with `enabled: true`, and the optional root policy ceiling must allow it. `doctor` reports the grant passively. CLI, MCP and `settings.update` cannot enable it. The existing same-login consent boundary and independent Brain-file retrieval are unchanged.

Mac reads `People.swift`'s saved Person rows and persisted participant metadata from visible, indexed meetings in a single read transaction off the main thread. It does not scan transcripts, audio or live EventKit attendees. Owners are excluded from meeting participants. Hidden People names and emails suppress matching participant aliases, so old meetings cannot restore a hidden person. A shared hidden name is conservatively suppressed even if a different row has that name. Excluding a meeting stops participant fallback from that meeting; it does not delete independently saved People entries. Hide those entries separately when desired.

Linux/Omarchy uses the existing `people.md` export in the configured Brain and returns `source: "people_export"`. No display server is needed. The safe Brain reader rejects linked paths, malformed text and oversized files. Missing Brain/people export returns `unsupported_on_platform` once the grant check passes. A valid empty export returns `not_found`. Other source errors propagate; malformed person rows return `PEOPLE_SOURCE_INVALID` rather than a partial match set. Discovery advertises the implemented action without opening personal data.

Linux does not fall back to standalone meeting exports: those files have no hidden-person ledger, and using them could restore a person removed from `people.md`. This is an export snapshot, not a live People database or Contacts backend; refresh it to reflect changes on the source Mac. Linux-native meeting recordings do not populate an address book in this step. There is no network contact service, OAuth, arbitrary path argument, or automatic sync.

## Limits and verification

Both matchers cap input identities at 10,000 and fail with `PEOPLE_LIMIT_EXCEEDED` instead of silently truncating the source and claiming uniqueness. Mac caps meeting rows at 10,000, each participant JSON at 256 KiB, and aggregate participant JSON at 8 MiB. Invalid saved participant JSON returns `PEOPLE_SOURCE_INVALID`. Linux inherits the Brain document limit (2 MiB). Ordinary candidate pagination is separate from source completeness.

Shared synthetic fixtures check Mac/JavaScript matching, duplicates, accents, case, prefix confirmation, missing emails, exact emails and ambiguity at a limit of one. Native database tests cover hidden People, excluded meetings, owner exclusion, invalid participant metadata and no database writes. CLI/MCP tests cover source and standalone bundles, default-off grants, named scopes, revocation and file safety. Real Contacts are never read in these tests. The permission control uses the existing keyboard-accessible Toggle with a VoiceOver hint and no added animation.
