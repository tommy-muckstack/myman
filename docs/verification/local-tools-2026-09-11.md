# Local preview verification — September 11, 2026

This report records the local verification completed before the user authorized
the 1.1.59 release. Version 1.1.58 was published separately. These checks did not
replace the installed app or the user's production library.

## Interface

- Search/History/Themes tabs are removed. Recent captures appear under the
  search field; the funnel menu opens Themes and content/date/pin filters.
- The supplied filter and Themes SVGs live in the central icon library. Native
  menus use template images rendered from those same paths.
- Calendar, tasks, new notes, meeting notes/transcripts, Search, Themes,
  related captures, screenshot text and the existing beta chat share a centered
  empty-state component. Typing and image drops pass through the note invitation.
- Recording-title expansion has one native window animation, anchored at the
  top right. Controls remain at the same coordinates while the field unfolds
  below. Hover-exit handling waits for resize to finish and checks the pointer's
  actual location. Reduced Motion uses an immediate resize.
- Destructive history clearing lives in capture/privacy settings. No capture
  data was removed as part of removing the navigation tab.

## Automated and native checks

- Full Swift run: **144 tests, 4 opt-in skips, 0 failures**. Skips require private
  concept/meeting review data, synthetic meeting benchmark audio, or an explicit
  screenshot-control visual-review flag.
- Subsequent interface/editor/meeting checks: **30 tests, 0 failures**; final
  native menu-icon/empty-state render check also passed.
- CLI/MCP regression suite: **29 passed**.
- Font engine regression suite: **16 passed**; TypeScript checks and both
  packaged-resource freshness checks passed.
- Universal release configuration builds for Apple Silicon and Intel. This is
  a compile check, not a published or notarized release.
- Native view renders were inspected at actual panel sizes. Intermediate-height
  recording-pill snapshots verify the controls remain pixel-identical while
  expanding; live title editing still autosaves without stopping recording.

## Live agent command coverage

The packaged preview ran with `MYMAN_VERIFICATION_ROOT` pointing at an isolated
`/private/tmp/man-verification-*` library. The harness exercised every advertised
schema: **45 app actions and all 10 exported retrieval tools**. It used real
AppKit, Vision, WebKit, capture and audio controllers, with synthetic content.

Verified flows include screenshot capture → annotations → clipboard image,
image import/OCR/background removal, video start/microphone control/stop → saved
movie, meeting start/rename/stop/discard, dictation start/stop/cancel, notes with
optimistic edit conflicts, task/theme/item mutations, font creation → valid OTF
→ saved project reopen, settings, and confirmed isolated-history clearing.
Completed job caches expire after a capture is deleted, including indirectly
related results. Existing request IDs cannot replay expired mutations.

Expected failure paths were checked explicitly: stale note edits, unconfirmed
history clearing, no separable foreground in a text-only screenshot, and silent
dictation producing no transcript. Meeting-notes retrieval used a cached fixture;
this run does not evaluate fresh AI summaries or real conversational accuracy.
The test machine granted screen and microphone access; permission-denied behavior
is guarded, but every possible macOS privacy configuration was not exercised.

Reproduce:

```sh
python3 scripts/package-local.py
MYMAN_VERIFICATION_ROOT=/private/tmp/man-verification-review \
  '.build/local/My Man Preview.app/Contents/MacOS/MyMan'
# In a second terminal, after ready.json appears:
node integrations/brain/test-all-native-actions.mjs /private/tmp/man-verification-review
```

The verification override exists only in debug builds. It does not change the
release library location. Do not run the destructive harness against normal data.

## Font quality and bounds

Native WKWebView checks exercised full-resolution OCR, bundled matching assets,
actual generated-font preview, OTF parsing, naming, cancellation and blocked
remote fetches. Additional withheld-glyph experiments bypass OCR entirely:
only `HOnolmpeSI` outlines enter inference; original `ABg27?` outlines are loaded
later for comparison. Helvetica Neue, Georgia and Courier Bold are outside the
matching library. Source outlines are preserved and inferred flat-foot letters
share baseline zero.

Visual comparisons confirm the outputs are readable approximations, with
material differences in serif construction, letter widths, numeral style and
single/double-storey forms. Sparse examples cannot recover exact missing glyphs,
kerning, alternates or a whole family. Complex backgrounds and non-Latin scripts
remain outside this first basic-Latin workflow. Captured-only export and explicit
fallback alternatives remain available; inferred characters carry provenance and
review notes. No paid inference service or screenshot upload is used.

Local review artifacts: `/private/tmp/man-font-baseline-review/`,
`/private/tmp/man-empty-*.png`, `/private/tmp/man-recording-title-*.png`, and
`/private/tmp/man-verification-font-actions/all-actions-report.json`.
