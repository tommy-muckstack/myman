# Calendar proposals (step 4)

`calendar.propose` is a local dry run. It reads the owner's free/busy intervals, returns candidate slots and an **unconfirmed** preview, and writes no event, invitation, calendar file or Brain entry. It does not book. The Launcher scheduling interface and human Book action are later steps.

## Permissions and platforms

The human must enable **both** `calendar_read` and the new, default-off `calendar_propose` grant. Named credentials also need both scopes; credentials cannot enlarge owner grants. On Mac, use Settings → Agents → “Read calendar free/busy” and “Prepare calendar event previews”, plus existing human-granted macOS Calendar access. The action never requests OS permission or enables grants. Doctor reports both grants.

Linux and Omarchy use the same private, owner-configured local ICS snapshot as [calendar.freebusy](calendar-freebusy.md). The human enables both grants in `agents.json`, subject to any `/etc/myman/agents.json` ceiling. There is no agent command that grants access. Without `calendar.json`, discovery reports unsupported and execution returns `unsupported_on_platform`. Invalid or incomplete reads fail; they never become an empty, available calendar. No display server, network account, OAuth, CalDAV or Contacts access is involved.

## CLI and MCP

```sh
myman actions calendar.propose --json
myman calendar propose --title 'Coffee' \
  --after 2026-10-02T00:00:00-04:00 --before 2026-10-03T00:00:00-04:00 \
  --time-zone America/New_York --duration-minutes 45 \
  --guests '["Jilles","Harshil"]' --limit 3 --json
```

MCP tool: `myman_app_calendar_propose`. Its strict schema is generated from `integrations/brain/actions.json`; `readOnlyHint` is true. The same arguments work with `myman invoke calendar.propose JSON --json`. Guest strings are **display labels only**. A later caller can compose the separate scheduling parser and people resolver; this action does neither lookup. It does not verify guest identity or availability, and never treats these labels as invitation recipients.

| Argument | Contract |
| --- | --- |
| `title` | Required nonblank text, at most 200 Unicode scalars, no control characters |
| `after`, `before` | Required ISO timestamps with seconds and UTC offsets; inclusive start, exclusive end, positive range at most 31 elapsed days |
| `time_zone` | Required IANA zone (for example `America/New_York`) or `UTC`; independent of the ICS import zone |
| `duration_minutes` | Elapsed minutes, integer 1–480; default 30 |
| `limit` | Returned slot count, integer 1–20; default 5 |
| `guests` | Up to 20 nonblank labels, each at most 200 Unicode scalars; defaults to empty |
| `proposed_starts` | Optional 1–100 explicit ISO instants; substitutes exact proposed starts for the default grid |

The default grid checks quarter-hour local starts from 09:00, finishing by 18:00 on the same local date. Every requested day is considered, including weekends. DST and fractional-hour offsets use the supplied zone. Durations are elapsed minutes. No workweek or personal working-hours preference is inferred.

Explicit `proposed_starts` may be outside these hours or off-grid. They are deduplicated and sorted by absolute time; offsets disambiguate repeated local times. Malformed timestamps fail validation. Valid starts in the past, outside the requested range, extending past `before`, or conflicting with any own busy interval are omitted. Half-open intervals allow a meeting ending exactly when a busy block starts. All candidates are counted before applying `limit`. The action uses the actual clock after reading availability; callers cannot override it or supply their own busy intervals.

## Result

Illustrative result excerpt (the full `availability` object also includes the free/busy query bounds, merged intervals and completeness):

```json
{
  "slots": [{"start":"2026-10-02T13:00:00.000Z","end":"2026-10-02T13:45:00.000Z"}],
  "candidate_count": 34,
  "truncated": true,
  "slot_source": "workday_grid",
  "preview": {
    "title":"Coffee",
    "start":"2026-10-02T13:00:00.000Z",
    "end":"2026-10-02T13:45:00.000Z",
    "time_zone":"America/New_York",
    "duration_minutes":45,
    "guests":["Jilles","Harshil"],
    "guest_count":2,
    "calendar_scope":"own_calendar",
    "send_invitations":false,
    "requires_human_book":true,
    "video_link":null,
    "complete":true
  },
  "dry_run":true,
  "side_effects":false,
  "booked":false,
  "booking_supported":false,
  "teammate_availability":"unknown"
}
```

The preview uses the earliest returned candidate as a suggestion. With no candidates, `slots` is empty, `candidate_count` is zero, `truncated` is false, and the preview has null start/end and `complete:false`. Neither form is a confirmation or a reservation. `availability.source` is `eventkit` or `local_ics`; Linux also reports `freshness:"local_snapshot"`. Source events' titles, IDs and attendees never appear.

Availability can change after the read, and ICS can be stale. Any future booking implementation must recheck availability, show a human preview and require a human Book press. The current schema rejects booking, confirmation, invite, path, busy-block and clock arguments. Video links remain absent.

## Verification

Swift and Node run the same synthetic slot fixtures: 30/45-minute durations, busy overlaps, boundary adjacency, past times, no slots, DST, Kathmandu, exact proposed starts and the maximum 31-day range. Native tests verify default-off grants, settings rejection and named scope revocation. Linux source/bundled CLI and MCP tests verify both grants, unsupported configuration, errors, guest labels, no source mutation and live revocation. These are fixture checks, not real Calendar access, marketplace host activation or a physical Omarchy desktop test.
