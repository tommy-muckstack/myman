# Local-first time conversions

Single-place queries now interpret the clock time in the Mac's current time zone and show the requested destination. The card and copied text follow source → destination. Explicit two-place queries still honor the stated direction.

Synthetic native card renders use October 8, 2026 and America/New_York:

| Query | Your time | Destination |
| --- | --- | --- |
| `9am in Iceland` | 9:00 AM EDT | 1:00 PM Iceland |
| `5pm in Houston` | 5:00 PM EDT | 4:00 PM CDT |
| `5pm in DC` | 5:00 PM EDT | 5:00 PM EDT |

![Iceland conversion](images/local-time-iceland.png)
![Houston conversion](images/local-time-houston.png)
![DC conversion](images/local-time-dc.png)

Houston, Houston TX and Houston Texas resolve to Central regional rules. DC, D.C., Washington DC, Washington, D.C. and District of Columbia resolve to Eastern regional rules. Labels preserve the destination city. Additional common cities resolve locally without geocoding or network requests; this is a finite alias list plus the system's IANA time-zone names, not a worldwide city search.

Regression coverage verifies summer/winter offsets, local calendar dates, a Tokyo local zone, midnight rollover, skipped/repeated local daylight-saving hours, explicit reverse conversions, fixed-offset labels, copied-text order and the native agent evaluator's source/destination fields. Native card fixtures are opt-in with `MYMAN_TIMEZONE_SCREENSHOTS`.

Validation on October 8, 2026: debug and universal arm64/x86_64 release builds passed; native suite 529 tests, 39 skipped, zero failures; Brain companion 155 tests, zero failures; committed bundle check passed. All three native card images were visually inspected.

The native agent evaluator shares this parser. Root plugin candidate 0.17.1 therefore documents the corrected semantics; Brain 0.16.0, Linux 0.17.0 and Grok 0.12.0 remain unchanged. Linux time-zone evaluation remains unsupported. The candidate is prepared, not submitted or host-verified. The next marketplace step is an authorized update email to marketplace-publishing@cursor.com with org @muckstack, repository https://github.com/tommy-muckstack/myman and candidate 0.17.1; do not duplicate the pending publisher application. No email was sent.
