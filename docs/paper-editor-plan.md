# Paper-inspired editors and Gellix

## Audit

- Notes (`NoteDocumentView`) and meeting summaries (`MeetingDocumentView`) already share `RichMarkdownEditor`, an AppKit text view hosted in SwiftUI. Extend this component.
- Notes store their title as the first line of Markdown; meetings have an explicit title plus separate summary/transcript fields. Keep these models and existing search triggers.
- The editor already hides basic Markdown markers and offers selection-based bold, italic and underline. It currently conflates heading levels, infers structure from font sizes, lacks proper formatting undo, and has no link/block controls.
- Note windows are 520 × 480 with 15-point body text and 24-point titles. Meeting windows are 680 × 640. Neither constrains long line lengths on large windows.
- Autosave debounces writes, but errors are swallowed and summary/transcript edits share a cancellation task. Improve save reporting and flush pending document edits when closing or switching sections.
- All shared typography is Outfit, with additional hard-coded AppKit fonts in the screenshot editor and Markdown editor. Gellix supplies Light, Regular, Medium and SemiBold, each with genuine italic faces.

## Design and implementation

1. Bundle the supplied Gellix TTFs; replace the shared font API and remaining direct font references. Use SemiBold for the previous Bold token, since no Bold face was supplied. Update contributor guidance to match the requested font.
2. Establish document tokens: generous title/body sizes, paragraph rhythm, 680-point readable column, responsive margins and larger default windows. Keep native window controls, light/dark appearances and scroll behavior.
3. Extend the existing Markdown codec with explicit block metadata and reliable round trips for headings, bullets, numbered lists, checklists, quotes, links and inline formatting. Preserve unsupported Markdown as text. Keep the stored format and database schema.
4. Add a small selection toolbar, a discoverable insert menu, keyboard formatting, slash quick-add, list continuation/exit, clickable checklist markers, native undo and link editing. Keep controls near the writing context instead of a permanent ribbon.
5. Apply the same writing surface to notes and meeting notes. Keep transcript reading/correction and captured slides accessible. Allow manual writing in an empty meeting document, including while its existing summary generation is pending; never overwrite a user's new draft with a late summary.
6. Verify formatting round trips, Unicode ranges, undo/redo, typing, list behavior, persistence and fonts. Render and inspect native light/dark document fixtures at narrow and wide sizes. Run the full test suite and debug/universal release builds before publishing.

## Boundaries

This is a local writing experience, not collaborative document hosting or a Dropbox integration. No database migration, remote editor, new account, background agent, or new dependency is needed. Quick capture remains fast; full documents provide the richer editing surface.

Reference: [Paper selection formatting](https://help.dropbox.com/view-edit/formatting) and [quick-add commands](https://help.dropbox.com/view-edit/quick-add-commands?fallback=true).
