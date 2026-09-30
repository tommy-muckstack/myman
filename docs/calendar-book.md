# Human-confirmed calendar booking

The Launcher’s **Review event** button opens a separate native confirmation window. Review the title, date, time, time zone, guest labels and destination calendar, then press **Book**. Tab through controls and use Space or VoiceOver to activate Book; Return is deliberately not a default confirmation shortcut. Escape cancels. The UI uses semantic contrast tokens and adds no animation.

Calendar access requires the human’s existing OS Full Calendar Access and both `calendar_read` and new default-off, owner-only `calendar_write` grants in Settings → Agents. Named credentials need both scopes. Neither CLI/MCP nor settings mutation actions can enable either grant or request OS permission. `doctor` reports `calendar_write` through the existing grants map. The Launcher also uses the parsing/proposal grants described in [Launcher scheduling](launcher-scheduling.md).

## Agent contract

```sh
myman calendar book --title 'Coffee with Mary' --start '2030-10-01T11:00:00-04:00' --time-zone America/New_York --duration-minutes 30 --guests '["Mary"]' --json
myman calendar booking --booking-id RETURNED_REQUEST_ID --json
```

Action `calendar.book` / MCP `myman_app_calendar_book` validates and presents an immutable event preview. Its immediate result is `status: "awaiting_human_confirmation"`, `booked: false`, `requires_human_book: true`, a `request_id`, `expires_at` and `preview`. **This result does not mean an event was created.** Only the human Book control can call the writer. Agents must not automate that control. My Man’s existing demo controls refuse clicks or typing into My Man windows.

Action `calendar.booking` / MCP `myman_app_calendar_booking` accepts `booking_id` (the returned `request_id`) and reads the receipt for the same requesting credential. Polling never writes. The strict schemas expose no confirmation flag/token, destination override, attendees, invitations or video link. `start` must be a future ISO timestamp including seconds and a UTC offset; `time_zone` must be an IANA zone or UTC. Duration is required, 1–480 minutes; title is 1–200 characters and at most 20 guest labels of 200 characters each. The human selects the writable destination in the preview.

The immutable preview expires after ten minutes. Closing it cancels; a second request cannot replace a pending preview or an in-progress save (`CONFIRMATION_PENDING`). Receipts are in memory, capped at 100 requests (older receipts are evicted when the cap is reached), and do not survive app restart. Other credentials get `NOT_FOUND`. Receipt states are `awaiting_human_confirmation`, `saving`, `booked`, `cancelled`, `expired` and `failed`. A successful save remains `booked` even if EventKit supplies no event identifier.

Before saving, My Man rechecks the owner grants, OS permission, requesting credential, future start, writable calendar and current own-calendar busy blocks. A new conflict fails with `CALENDAR_CONFLICT`. A single preview can attempt only one save, including after an uncertain failure. On `CALENDAR_SAVE_FAILED`, inspect Calendar before preparing another request; never automatically retry a booking after an error, disconnect or restart.

A fresh EventKit event is saved only to the chosen owner-accessible calendar. Guest labels become event notes; no attendees are set and no invitations are sent. Teammate availability remains unknown. There is no Contacts lookup, account login, video-link creation or Brain export write.

## Platform support and verification

Both booking actions return `unsupported_on_platform` on Linux and Omarchy, including when local ICS free/busy is configured. Linux does not expose a pretend `calendar_write` grant. ICS reading and dry-run proposals remain available.

Verification uses synthetic session writers, isolated credential registries, strict CLI/MCP schema tests, and source/bundled Linux unsupported checks. The debug-only booking fixture uses a fake writer and never touches EventKit. Visual review and automated tests do not claim a real calendar event or invitation was sent. No media is committed.
