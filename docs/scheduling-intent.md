# Scheduling intent (step 1)

`scheduling.parse` interprets English text into an **unsaved, unconfirmed intent**.
It does not query calendars, Contacts, People or voice profiles, propose free
slots, create events, send invites, or generate video links. Those are later steps.
A complete parse is never authority to book; booking will need a human preview
and a human pressing Book.

## CLI and MCP

In **Settings → Agents**, the owner enables **Parse meeting requests without
accessing calendars**. This new `scheduling_parse` grant starts off, independently
of library/calendar permissions. Named agents also need the matching scope,
issued by the owner in Settings. `doctor` reports the grant. No CLI, URL, MCP or
settings action can turn it on. Parsing requests no OS permission; calendar
read/write grants and OS prompts belong to the later calendar steps.

```sh
myman scheduling parse --input "meeting with jilles and harshil" --json
myman scheduling parse --input "Coffee with Developer Friday at 10am for 30 min" \
  --reference 2026-09-29T16:00:00Z --time-zone America/New_York --use-model off --json
myman actions scheduling.parse
```

MCP tool: `myman_app_scheduling_parse`, with arguments `input`, optional
`reference`, `time_zone`, and boolean `use_model`. The generic
`myman invoke scheduling.parse '{"input":"meeting with Alex","use_model":false}'`
has the same contract. `actions.json` is the authoritative schema. Source and
bundled CLI/MCP advertise the action on Linux/Omarchy but return
`unsupported_on_platform`; no Linux parser is claimed in step 1.

The second example returns these fields (the CLI adds its normal receipt IDs):

```json
{
  "title": "Coffee",
  "people": ["Developer"],
  "day": "2026-10-02",
  "time": "10:00",
  "duration_minutes": 30,
  "time_zone": "America/New_York",
  "reference": "2026-09-29T16:00:00Z",
  "missing": [],
  "issues": [],
  "needs_clarification": false,
  "engine": "deterministic",
  "side_effects": false,
  "requires_human_booking": true
}
```

The first example yields title `meeting`, people `jilles` and `harshil`, and
null day/time/duration. Mentions are not verified people or email addresses.
Missing values are always null; there is no default date, time or duration.
`missing` lists title/day/time/duration fields still needed. `issues` flags
ambiguous, invalid or unsupported syntax; callers must surface clarification.
`needs_clarification: false` means only that the text supplied all four fields.
It is not a valid-time, availability, identity, permission or booking check.

## Shared parser and model boundary

`SchedulingIntentParser` is pure Foundation code shared by native consumers and
the agent handler. Callers supply a reference instant and a time zone; the handler
defaults to now and the Mac's zone and echoes them in JSON. Gregorian calendar
arithmetic respects day boundaries and daylight-saving changes. Day and wall time
stay separate; validating nonexistent/repeated local times, past events and
availability belongs to the future proposal action.

Detector-style rules accept `today`, `tomorrow`, full English weekday names,
`this Friday`, `next Friday`, ISO `YYYY-MM-DD`, `10am`, `2:30pm`, `at 14:30`,
`noon`, `midnight`, and `for 30 min` / `for 0.75 hours`. Weekdays mean the next
occurrence including today; `next` skips today if it matches. Duration must be
an integral 1–480 minutes. A bare `at 10` needs AM/PM clarification. Inputs are
bounded to 2,000 characters. Names after `with` split on commas, `and` or `&`,
retain spelling/Unicode and deduplicate case-insensitively.

Vague periods, recurrence, conflicting dates/times/durations, non-ISO numeric dates,
word-number times/durations and time zones embedded in text require clarification.
Use the `time_zone` argument instead. English is the v1 grammar; there is no
locale-dependent NSDataDetector call that can secretly use a different clock.

On macOS 26+ with Apple Intelligence available, `SchedulingIntentService` can
extract literal title/person spans for requests without clear `with` syntax
(e.g. `Alex and Sam coffee Friday at 10am for 30 min`). Clear deterministic parses
and flagged ambiguous requests do not need the model. The model never supplies
calendar fields; generated names and titles must occur verbatim in the input,
and temporal mentions cannot become people. A three-second deadline, unavailable
model, refusal, error, cancellation or invalid extraction returns the deterministic
result. No cloud, account, tool calling or contact lookup is involved.

## Review decisions

- Start with English; add languages only with explicit grammar and fixtures.
- Keep unknown duration null; a later UI may offer 30/45-minute choices visibly.
- Resolve full weekday names by the policy above; revisit `next Friday` wording
  before exposing the scheduling UI if a different convention is preferred.
- Teammate availability, invite sending, Linux ICS/CalDAV and video-link choices
  remain open for their respective steps; none is needed by this parser.

## Verification (2026-09-29)

- Swift debug compilation and full native suite: 481 tests, 39 skipped, zero failures;
  includes 11 new scheduling tests (both demo phrases, vague/invalid/conflicting
  input, Unicode people, calendar day arithmetic, model validation/fallback,
  JSON, and default-off grant enforcement).
- Universal release build (`arm64` + `x86_64`) passes with Xcode 27 / Swift 6.4.
- Brain companion: 112 tests pass; source and bundled MCP expose the strict parser
  schema and propagate permission denial. Both companion bundle checks pass.
- Linux parser contract: four focused source/bundled CLI/MCP tests pass, including
  explicit unsupported results and discovery metadata. This Mac lacks `xvfb-run`;
  full Ubuntu/Xvfb and Omarchy coverage remains with GitHub Linux CI.
- Live isolated debug preview advertises `scheduling.parse` and returns
  `AGENT_DISABLED` with its new grant off. Settings screenshot captured outside
  the repository; no media committed. No production grants were changed.
- Model tests inject synthetic extraction/failure/unavailable results. They do not
  claim live Apple Intelligence model quality or marketplace host activation.

Two pre-existing theme-existence reads in `AgentActions` also needed `await` for
Swift 6.4/GRDB overload resolution so the native build and tests could run.
