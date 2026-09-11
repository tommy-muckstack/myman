# A small, capable document editor

Man already shares one native NSTextView editor between notes and meeting notes. Markdown is the durable format, inline formatting lives in attributed-string metadata, document saves are debounced and reversible, and the slash menu / Insert menu already provide headings and lists. Extend those components.

## Interaction plan

- Drop, paste, or insert a local image at the cursor. Store an owned copy with the document, display a scaled preview, and open the full-resolution image in a full-screen viewer on click. Escape closes it. Keep local assets portable in the Brain folder and remove owned assets when the document is deleted; never delete the source screenshot.
- Insert a modest table through `/table` or Insert. Edit cells directly, move between cells with Tab/Shift-Tab, append a row from the last cell, and offer small contextual row/column controls. Preserve Markdown tables and inline formatting through save, reopen, copy, and undo.
- Convert `* ` and `- ` on an empty line into bullets, with numbered lists and headings using the same mechanism. Enter continues a list; Enter on an empty item exits. Backspace removes a list marker. Typing inside code stays literal.
- Command-B / Command-I apply to a selection or toggle the style for future typing. Preserve selection, mixed formatting, focus, composition, and a predictable undo history.
- Keep the existing quiet Gellix document surface. No persistent ribbon, formatting sidebar, or spreadsheet features.

## Reference behavior

Dropbox documents [drag-and-drop and menu-based image insertion](https://help.dropbox.com/view-edit/insert-files), [slash insertion and small contextual table controls](https://help.dropbox.com/view-edit/create-table), and [typing/keyboard shortcuts](https://blog.dropbox.com/topics/work-culture/paper-101-keyboard-shortcuts). The full-screen image interaction is also an explicit user requirement. Native AppKit attachment and NSTextTable APIs let these features retain the current editor and its keyboard / undo behavior.

## Verification

Native tests exercise the drag destination with a file pasteboard, clipboard images, independent owned copies, original-file deletion, preview opening/closing, Markdown round trips, table edits and keyboard navigation, selected/future text formatting, list conversion, undo/redo, and composition safety. Native screenshots cover images and tables at 560pt and 820pt in both appearances. The full suite has 100 tests (99 passing; one optional benchmark skipped). Debug and universal Apple silicon/Intel release builds are required before publishing.

Tables deliberately stay small: up to six columns and 100 rows, editable inline with contextual row/column actions. Enter adds a line inside a cell; Escape moves below the table. Full-resolution images stay in the document’s owned assets folder; inline rendering uses a bounded thumbnail. Assets removed from the page remain available for undo until the owning document is deleted. Existing Brain backups include the assets folder alongside Markdown.
