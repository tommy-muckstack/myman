# Calendar free/busy

`calendar.freebusy` is a read-only scheduling primitive. It returns the owner's busy intervals, not teammates' availability. It does not resolve people, propose slots, book events, send invitations or create video links.

```sh
myman calendar free --after 2026-09-29T00:00:00-04:00 --before 2026-09-30T00:00:00-04:00 --json
myman invoke calendar.freebusy '{"after":"2026-09-29T00:00:00-04:00","before":"2026-09-30T00:00:00-04:00"}' --json
myman actions calendar.freebusy --json
```

MCP tool: `myman_app_calendar_freebusy`, with the same required `after` and `before` arguments. The canonical schema is in `integrations/brain/actions.json`. Both values must include a date, seconds and explicit UTC offset (`Z` or `±HH:MM`); one to three fractional-second digits are accepted. The positive range is limited to 31 elapsed 24-hour days. Use local midnight offsets for day boundaries, accounting for daylight saving time.

Example result (inside the normal CLI/MCP success envelope):

```json
{
  "after": "2026-09-29T04:00:00.000Z",
  "before": "2026-09-30T04:00:00.000Z",
  "busy": [{"start":"2026-09-29T14:00:00.000Z","end":"2026-09-29T15:00:00.000Z"}],
  "source": "eventkit",
  "scope": "own_calendar",
  "complete": true,
  "side_effects": false,
  "teammate_availability": "unknown"
}
```

Intervals are half-open `[start,end)`, clipped to the query, sorted, and merged when overlapping or adjacent. No titles, attendees, event IDs or calendar names are returned. Canceled, explicitly free/transparent and owner-declined events are excluded; tentative and unknown availability count as busy. All-day events use exclusive end dates. A successful empty list means no busy blocks in the selected local source, not that every invitee is available. `complete` means this source was processed without truncation; it does not establish synchronization freshness or coverage of other calendars.

## Human permission

`calendar_read` is a new default-off grant, independent of `library`. On Mac, the human enables **Read calendar free/busy** in Settings → Agents, plus **Allow local app commands**. A named credential also needs the `calendar_read` scope; old credentials gain no scopes automatically. The OS must already have granted MyMan Full Calendar Access through its human permission flow. The action checks authorization without showing an OS prompt and returns `PERMISSION_REQUIRED` when access is absent. No CLI, MCP or settings action can enable these grants. `doctor` reports grant and OS status passively.

The existing Mac `calendar.list` action retains its existing `library` and OS permission checks. The new grant governs `calendar.freebusy`; it does not change previous agenda behavior.

Mac reads EventKit's locally configured calendars on a background queue, including recurring and all-day events. It does not query another person's account or fetch remote free/busy. The user's Calendar app may independently synchronize its configured accounts. EventKit's all-calendar predicate is used; selecting specific calendars is not implemented here.

## Linux and Omarchy: local ICS snapshot

The human configures `${XDG_CONFIG_HOME:-~/.config}/myman/calendar.json`:

```json
{
  "version": 1,
  "ics_path": "/absolute/path/to/owner-calendar.ics",
  "time_zone": "America/New_York",
  "owner_email": "owner@example.test"
}
```

The config directory must be owned by the login and mode `700`; `calendar.json` and the ICS must be owned, unlinked regular files with mode `600`. `ics_path` is an absolute local path, never a URL. The optional `owner_email` identifies declined invitations; without it, attendee RSVP data is conservatively treated as busy. Floating and all-day times use `time_zone`. There is no CLI/MCP path override, network calendar backend, OAuth, account setup or automatic sync.

The human separately enables `enabled` and `calendar_read` in the existing `agents.json`. Missing grants stay off, named credential scopes only narrow them, and an optional root-owned `/etc/myman/agents.json` ceiling must also allow the grant. Neither installation nor discovery changes permissions. These are the existing same-login consent controls, not an OS sandbox against an agent with arbitrary file access.

Without `calendar.json`, the action returns `unsupported_on_platform`, and discovery reports `supported: false`. An invalid config returns `INVALID_CALENDAR_CONFIG`. `doctor.calendar` reports configuration and `live_sync: false` without opening the ICS; configured does not mean the file has been parsed. Results use `source: "local_ics"` and `freshness: "local_snapshot"`. This works without X11 or Wayland, including Omarchy, and does not access Contacts.

ICS parsing uses pinned [ical.js 2.2.1](https://github.com/kewisch/ical.js/) in a separate bounded worker. It handles UTC, floating and IANA times, embedded `VTIMEZONE`, `RRULE`, `RDATE`, `EXDATE`, moved/canceled `RECURRENCE-ID` instances, and `VFREEBUSY`. Embedded time-zone definitions take precedence. Without one, IANA wall times use the host's `Intl` zone data. Repeated wall times conservatively cover both occurrences; nonexistent times fail.

Ambiguous or unsupported forms return `ICS_UNSUPPORTED`, including `EXRULE`, `RANGE=THISANDFUTURE`, period-valued `RDATE`, mismatched date/time-zone forms for exceptions or exclusions, mixed-zone starts/ends, and UTC `UNTIL` bounds on IANA series lacking `VTIMEZONE`. Use an export with complete time-zone definitions or bounded expanded events for these cases. Unknown recurrence extensions are rejected. Malformed ICS returns `INVALID_ICS`; unreadable/unsafe source files return `CALENDAR_UNAVAILABLE`. Errors never masquerade as an empty calendar.

Limits: config 16 KiB, ICS 8 MiB, 10,000 events/busy blocks, 20,000 recurrence iterations from the series origin, and a three-second worker deadline. Mac also caps matched events at 10,000. Exceeding expansion limits returns `CALENDAR_LIMIT_EXCEEDED` without a partial result; choose a smaller export/range. The worker is included in standalone bundles, the installer and the Arch package.

## Verification

Synthetic native tests cover bounds, interval merging, all-day/DST intervals, event status filtering, metadata omission and independent default-off consent. Source and bundled Linux CLI/MCP tests cover ICS parsing, exceptions, DST, file safety, absent configuration, schema discovery and live grant revocation. Tests never read a personal calendar or trigger OS consent. Physical Omarchy and real EventKit store reads remain human/host checks; no teammate availability or booking is claimed.
