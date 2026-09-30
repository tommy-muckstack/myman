# Launcher scheduling

Type “schedule with Mary”, “meeting with Jilles and Harshil” or “Coffee with Developer Friday at 10am for 30 min” into the Launcher. Search requests (for example “find meeting with Mary”) remain searches; “my schedule” remains the read-only agenda.

The scheduling view shows guest labels, an editable title/date, 15-minute duration controls, a 9–6 timeline and candidate time pills. Click/drag your row or focus it and use left/right arrows to adjust by 15 minutes. A native time picker provides another keyboard and VoiceOver path. Every guest row explicitly says availability is not shared; only the owner's calendar contributes free/busy. Resolved saved people can be chosen in each chip menu; unresolved names stay labels, never guessed identities or invitation addresses. No Contacts or teammate account access occurs.

Date/time defaults are visible and editable. The view preserves parser warnings, discards stale asynchronous reads, and clears selections when the date/duration/request changes. Permission/read errors remain visible; unknown availability is never displayed as free. Controls use native focus behavior, VoiceOver names, semantic contrast tokens and reduced-motion preferences. The Launcher keeps its deferred, explicit window sizing and scrolls on smaller screens.

The existing default-off `scheduling_parse`, `calendar_read`, `calendar_propose` and optional `people_read` owner grants apply. Calendar permission is requested only from a human-clicked button. The interface does not enable grants itself. Open Settings to choose them, then Check again. Review event opens the separate [human-confirmed booking window](calendar-book.md), which additionally requires the new default-off `calendar_write` grant. Only pressing Book there creates an event.

Agents can open the empty scheduling surface with `myman invoke app.open '{"surface":"schedule"}' --json` / MCP `myman_app_app_open` with `surface: "schedule"`. Existing `scheduling.parse`, `people.resolve` and `calendar.propose` actions provide structured inputs/results. Opening a surface adds no data-access grant. Linux/Omarchy has no native Launcher and returns `unsupported_on_platform` for `app.open`; local ICS/People CLI workflows remain available.

Verification uses synthetic calendars and people, routing tests, conflict boundaries, permission denial/revocation and delayed-read invalidation. No personal data or screenshot media is committed.
