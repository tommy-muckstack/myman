import XCTest
import AppKit
import SwiftUI
import GRDB
@testable import MyMan

final class PaperEditorTests: XCTestCase {
    private let sample = "A quieter place to think\nCapture the thought. Give it room to become something useful.\n\n## Make space for good work\nA simple document with **clear emphasis**, *a softer aside*, and a [useful reference](https://example.com).\n\n- Keep the important things easy to find\n- Leave room for the next idea\n\n### Next time we meet\n- [ ] Bring the new sketches\n- [x] Share the first draft\n\n> Good notes make the next conversation better."

    @MainActor func testGellixFacesAreBundledAndActuallyUsed() throws {
        MM.Fonts.registerFonts()
        for weight in [MM.Fonts.GellixWeight.light, .regular, .medium, .semiBold, .bold] {
            for italic in [false, true] {
                let font = MM.Fonts.native(17, weight, italic: italic)
                XCTAssertTrue(font.fontName.hasPrefix("Gellix"), font.fontName)
                XCTAssertEqual(font.fontName.contains("Italic"), italic)
            }
        }
    }

    func testMarkdownRoundTripsPreserveBlockLevelsAndInlineContent() {
        let sources = [sample, "# Original title\n### Third heading\n1. First\n2. Second\n  - Nested\n", "Title\n<u>**underlined bold**</u> and **bold *italic* words**.\n***Both*** ~~done~~ `x = 1`", "Title\n```swift\nlet raw = \"**keep markers**\"\n```\n| A | B |\n|---|---|\n| 1 | 2 |", "Title\n[Link](https://example.com/a\\(b\\))\n![image](file:///private/image.png)", "Title\n👩🏽‍💻 café 日本語\n- [X] Done\n\n"]
        for source in sources {
            let rich = MarkdownRich.attributed(from: source)
            let saved = MarkdownRich.markdown(from: rich)
            XCTAssertEqual(saved, source)
            XCTAssertEqual(MarkdownRich.attributed(from: saved).string, rich.string)
        }
    }

    func testPlainTextKeepsWordsAndHidesFormatting() {
        XCTAssertEqual(MarkdownRich.plainText("## Heading\n**Bold** and [link](https://example.com)"), "Heading\nBold and link")
        let unsafe = "[Keep this](javascript:alert)"
        XCTAssertEqual(MarkdownRich.markdown(from: MarkdownRich.attributed(from: unsafe)), unsafe)
    }

    @MainActor private func host<V: View>(_ view: V, size: NSSize = MM.Document.windowSize) async throws -> DocumentWindow {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let window = DocumentWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor private func editor(in view: NSView) -> RichNoteTextView? {
        if let text = view as? RichNoteTextView { return text }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    @MainActor func testTypingFormattingUndoAndUnicodeSelection() async throws {
        var markdown = "Title\nHello 👩🏽‍💻 world"
        let window = try await host(RichMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 })))
        defer { window.contentView = nil; window.close() }
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        window.makeFirstResponder(text)
        let selected = (text.string as NSString).range(of: "👩🏽‍💻")
        text.setSelectedRange(selected)
        text.toggleBoldSelection()
        XCTAssertTrue(markdown.contains("**👩🏽‍💻**"), markdown)
        text.undoManager?.undo()
        XCTAssertEqual(markdown, "Title\nHello 👩🏽‍💻 world")
        text.undoManager?.redo()
        XCTAssertTrue(markdown.contains("**👩🏽‍💻**"))
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertNewline(nil)
        text.insertText("A fresh paragraph", replacementRange: text.selectedRange())
        XCTAssertTrue(markdown.hasSuffix("\nA fresh paragraph"), markdown)
        let last = try XCTUnwrap(text.textStorage?.attribute(.font, at: (text.string as NSString).length - 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(last.pointSize, MM.Document.bodySize)
    }

    @MainActor func testListsContinueExitAndCheckboxesToggle() async throws {
        var markdown = "Title\n1. First"
        let window = try await host(RichMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 })))
        defer { window.contentView = nil; window.close() }
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertNewline(nil)
        text.insertText("Second", replacementRange: text.selectedRange())
        XCTAssertEqual(markdown, "Title\n1. First\n2. Second")
        text.insertNewline(nil)
        text.insertNewline(nil)
        text.insertText("Plain again", replacementRange: text.selectedRange())
        XCTAssertTrue(markdown.hasSuffix("\nPlain again"), markdown)
        text.applyBlock(.checklist)
        XCTAssertTrue(markdown.hasSuffix("- [ ] Plain again"), markdown)
        let line = (text.string as NSString).lineRange(for: text.selectedRange())
        text.toggleChecklist(at: line)
        XCTAssertTrue(markdown.hasSuffix("- [x] Plain again"), markdown)
    }

    @MainActor func testSlashInsertionAndLinkEditing() async throws {
        var markdown = "Title\n"
        let window = try await host(RichMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 })))
        defer { window.contentView = nil; window.close() }
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText("/todo", replacementRange: text.selectedRange())
        text.updateSlashMenu()
        text.insertNewline(nil)
        text.insertText("Read the brief", replacementRange: text.selectedRange())
        XCTAssertEqual(markdown, "Title\n- [ ] Read the brief")
        let range = (text.string as NSString).range(of: "brief")
        text.setLink("https://example.com/brief", range: range)
        XCTAssertTrue(markdown.contains("[brief](https://example.com/brief)"), markdown)
        text.setLink("", range: range)
        XCTAssertFalse(markdown.contains("https://"))
    }

    @MainActor func testAutosaveCoalescesIndependentFieldsAndRetriesFailures() {
        let saver = DocumentAutosave()
        var title = "", body = "", fail = true
        saver.submit("title") { title = "Old draft" }
        saver.submit("title") { title = "Latest title" }
        saver.submit("body") { if fail { throw CocoaError(.fileWriteNoPermission) }; body = "Latest body" }
        saver.flush()
        XCTAssertEqual(title, "Latest title")
        XCTAssertEqual(saver.state, .failed)
        fail = false
        saver.flush()
        XCTAssertEqual(body, "Latest body")
        XCTAssertEqual(saver.state, .saved)
    }

    @MainActor func testCopyPasteWithinManPreservesFormatting() async throws {
        var markdown = "Title\n**Important** idea\n"
        let window = try await host(RichMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 })))
        defer { window.contentView = nil; window.close() }
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        text.setSelectedRange((text.string as NSString).range(of: "Important"))
        text.copyMarkdown(to: pasteboard)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.paste(from: pasteboard)
        XCTAssertEqual(markdown, "Title\n**Important** idea\n**Important**")
    }

    @MainActor func testClosingDocumentImmediatelyPersistsLastKeystrokes() async throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let note = Note(body: "Title\nOriginal")
        try await db.write { try note.insert($0) }
        let saver = DocumentAutosave()
        let window = try await host(NoteDocumentView(note: note, autosave: saver, store: NotesStore(database: db)))
        window.autosave = saver
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(" and the final thought", replacementRange: text.selectedRange())
        window.close()
        let saved = try await db.read { try Note.fetchOne($0, key: note.id) }
        XCTAssertEqual(saved?.body, "Title\nOriginal and the final thought")
        XCTAssertEqual(saver.state, .saved)
        window.contentView = nil
    }

    @MainActor func testDeletedNoteCannotBeRecreatedByAutosave() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let note = Note(body: "Deleted note")
        XCTAssertThrowsError(try NotesStore(database: db).updateDocument(note, body: "Late changes"))
        XCTAssertEqual(try db.read { try Note.fetchCount($0) }, 0)
    }

    @MainActor func testOpenMeetingReceivesPreparedNotesAndPreservesTyping() async throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let meeting = Meeting(id: "processing-editor", title: "A meeting", startedAt: Date(), transcript: "")
        try await db.write { try meeting.insert($0) }
        let window = try await host(MeetingDocumentView(meeting: meeting, database: db, automaticallySummarize: false))
        defer { window.contentView = nil; window.close() }
        let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(text.string.isEmpty)
        try await db.write { try $0.execute(sql: "UPDATE meeting SET transcript = 'Finished transcript', summary = 'Prepared notes' WHERE id = ?", arguments: [meeting.id]) }
        for _ in 0..<40 where text.string.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(text.string, "Prepared notes")
        try render(window, name: "meeting-prepared")
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(" with my additions", replacementRange: text.selectedRange())
        try await db.write { try $0.execute(sql: "UPDATE meeting SET summary = 'Late generated replacement' WHERE id = ?", arguments: [meeting.id]) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(text.string, "Prepared notes with my additions")
    }

    @MainActor func testRenderNotesAndMeetingsInBothAppearances() async throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let note = Note(body: sample)
        let meeting = Meeting(id: "paper-fixture", title: "A little clarity for next week", startedAt: Date(timeIntervalSince1970: 1789124400), endedAt: Date(timeIntervalSince1970: 1789126200), transcript: "", summary: String(sample.split(separator: "\n", maxSplits: 1)[1]))
        for dark in [false, true] {
            for width: CGFloat in [560, 1000] {
                let name = "\(dark ? "dark" : "light")-\(Int(width))"
                let window = try await host(NoteDocumentView(note: note, store: NotesStore(database: db)), size: NSSize(width: width, height: 800))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try render(window, name: "note-" + name)
                let text = try XCTUnwrap(editor(in: XCTUnwrap(window.contentView)))
                XCTAssertLessThanOrEqual(text.textContainer?.containerSize.width ?? 1000, MM.Document.columnWidth + 1)
                window.contentView = nil; window.close()
            }
            let window = try await host(MeetingDocumentView(meeting: meeting, database: db, automaticallySummarize: false), size: NSSize(width: 820, height: 800))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try render(window, name: "meeting-\(dark ? "dark" : "light")")
            window.contentView = nil; window.close()
        }
    }

    @MainActor private func render(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-paper-\(name).png"))
    }
}
