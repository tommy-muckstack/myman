import XCTest
import AppKit
import SwiftUI
@testable import MyMan

final class EditorBlocksTests: XCTestCase {
    @MainActor private func host(_ source: String, assets: DocumentAssets = .shared) async throws -> (DocumentWindow, RichNoteTextView) {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let window = DocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var value = source
        window.contentView = NSHostingView(rootView: RichMarkdownEditor(markdown: Binding(get: { value }, set: { value = $0 }), documentID: "note-test", assets: assets).background(MM.Colors.background))
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> RichNoteTextView? { (view as? RichNoteTextView) ?? view.subviews.lazy.compactMap(find).first }
        let editor = try XCTUnwrap(find(XCTUnwrap(window.contentView)))
        window.makeFirstResponder(editor)
        return (window, editor)
    }
    @MainActor private func save(_ editor: RichNoteTextView) -> String { MarkdownRich.markdown(from: editor.attributedString()) }
    @MainActor private func type(_ value: String, into editor: RichNoteTextView) {
        for character in value { editor.insertText(String(character), replacementRange: editor.selectedRange()) }
    }
    @MainActor func testTypedListsAndKeyboardFormatting() async throws {
        for marker in ["*", "-", "1."] {
            let (window, text) = try await host("Title\n")
            defer { window.contentView = nil; window.close() }
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
            type(marker + " ", into: text)
            XCTAssertFalse(text.string.contains("* "))
            XCTAssertEqual(text.typingAttributes[.manBlock] as? String, marker + " ")
            type("First", into: text)
            text.insertNewline(nil)
            type("Second", into: text)
            XCTAssertEqual(save(text), "Title\n\(marker) First\n\(marker == "1." ? "2." : marker) Second")
            text.insertNewline(nil); text.insertNewline(nil)
            type("Plain", into: text)
            XCTAssertTrue(save(text).hasSuffix("\nPlain"))
        }
        let (window, text) = try await host("Title\nHello world")
        defer { window.contentView = nil; window.close() }
        func command(_ key: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "b" ? 11 : 34))
            XCTAssertTrue(text.performKeyEquivalent(with: event))
        }
        text.setSelectedRange((text.string as NSString).range(of: "world"))
        try command("b")
        XCTAssertEqual(save(text), "Title\nHello **world**")
        text.undoManager?.undo()
        XCTAssertEqual(save(text), "Title\nHello world")
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        try command("i"); type(" next", into: text)
        XCTAssertEqual(save(text), "Title\nHello world* next*")
        try command("i"); type(" plain", into: text)
        XCTAssertEqual(save(text), "Title\nHello world* next* plain")
    }
    @MainActor func testTableEditingNavigationAndRoundTrip() async throws {
        let source = "Title\n| Name | Status |\n| :--- | ---: |\n| **Design** | Ready |\n| Café 日本語 | `a|b` |\n\nAfter"
        let (window, text) = try await host(source)
        defer { window.contentView = nil; window.close() }
        XCTAssertEqual(save(text), source)
        text.setSelectedRange((text.string as NSString).range(of: "Ready"))
        let table = try XCTUnwrap(text.currentTable)
        XCTAssertEqual(table.rows, 3); XCTAssertEqual(table.columns, 2)
        type("Done", into: text)
        text.insertNewline(nil); type("Today", into: text)
        XCTAssertTrue(save(text).contains("Done<br>Today"), save(text))
        XCTAssertEqual(text.currentTable?.rows, 3)
        text.insertTab(nil)
        XCTAssertEqual(text.currentTable?.current.row, 2)
        XCTAssertEqual(text.currentTable?.current.column, 0)
        text.insertBacktab(nil)
        XCTAssertEqual(text.currentTable?.current.row, 1)
        text.editTable("column")
        XCTAssertEqual(text.currentTable?.columns, 3)
        text.editTable("deleteColumn")
        XCTAssertEqual(text.currentTable?.columns, 2)
        let last = try XCTUnwrap(text.currentTable?.cells.last)
        text.selectTableCell(last); text.insertTab(nil)
        XCTAssertEqual(text.currentTable?.rows, 4)
        type("New row", into: text)
        text.exitTable(); XCTAssertNil(text.currentTable)
        let saved = save(text)
        XCTAssertEqual(MarkdownRich.markdown(from: MarkdownRich.attributed(from: saved)), saved)
    }
    @MainActor func testCellBoundariesCopyPasteAndUndo() async throws {
        let source = "Title\n| A | B |\n| --- | --- |\n| One | Two |\n| Three | Four |\n\nAfter"
        let (window, text) = try await host(source)
        defer { window.contentView = nil; window.close() }
        let start = (text.string as NSString).range(of: "One").location
        let end = NSMaxRange((text.string as NSString).range(of: "Two"))
        text.setSelectedRange(NSRange(location: start, length: end - start))
        text.deleteBackward(nil)
        XCTAssertEqual(text.currentTable?.rows, 3)
        XCTAssertEqual(text.currentTable?.columns, 2)
        XCTAssertTrue(save(text).contains("|  |  |"), save(text))
        text.undoManager?.undo()
        XCTAssertEqual(save(text), source)
        text.setSelectedRange(NSRange(location: NSMaxRange((text.string as NSString).range(of: "One")), length: 0))
        text.deleteForward(nil)
        XCTAssertEqual(text.currentTable?.current.column, 1)
        XCTAssertEqual(save(text), source)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        text.setSelectedRange((text.string as NSString).range(of: "One"))
        text.copyMarkdown(to: board)
        XCTAssertEqual(board.string(forType: NSPasteboard.PasteboardType("com.muckstack.myman.markdown")), "One")
        text.toggleBoldSelection()
        text.copyMarkdown(to: board)
        text.setSelectedRange((text.string as NSString).range(of: "Two")); text.paste(from: board)
        XCTAssertTrue(save(text).contains("| **One** | **One** |"), save(text))
        text.undoManager?.undo(); text.undoManager?.undo()
        XCTAssertEqual(save(text), source)
        text.setSelectedRange((text.string as NSString).range(of: "One"))
        board.clearContents(); board.setString("Red\tBlue\nGreen\tGold", forType: .string)
        text.paste(from: board)
        XCTAssertTrue(save(text).contains("| Red | Blue |\n| Green | Gold |"), save(text))
        text.undoManager?.undo(); XCTAssertEqual(save(text), source)
        let table = try XCTUnwrap(text.currentTable)
        text.setSelectedRange(table.range); text.cut(nil)
        XCTAssertFalse(save(text).contains("|"))
        text.undoManager?.undo(); XCTAssertEqual(save(text), source)
    }
    @MainActor func testCompositionAndCodeStayLiteral() async throws {
        let (window, text) = try await host("Title\n")
        defer { window.contentView = nil; window.close() }
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.setMarkedText("-", selectedRange: NSRange(location: 1, length: 0), replacementRange: text.selectedRange())
        text.insertText("- ", replacementRange: text.markedRange())
        XCTAssertEqual(save(text), "Title\n- ")
        XCTAssertFalse(text.string.contains("•"))
        text.selectAll(nil); text.insertText("Title\n", replacementRange: text.selectedRange())
        var attrs = text.baseAttributes(); attrs[.manCode] = "inline"; text.typingAttributes = attrs
        type("* ", into: text)
        XCTAssertFalse(text.string.contains("•"))
        XCTAssertTrue(save(text).contains("`* `"), save(text))
    }
    @MainActor func testSlashTableAndSpreadsheetPaste() async throws {
        let (window, text) = try await host("Title\n")
        defer { window.contentView = nil; window.close() }
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        type("/table 3x4", into: text)
        text.insertNewline(nil)
        XCTAssertEqual(text.currentTable?.rows, 3)
        XCTAssertEqual(text.currentTable?.columns, 4)
        text.editTable("remove")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("Name\tCost\nDesign\t$49", forType: .string)
        text.paste(from: board)
        XCTAssertEqual(text.currentTable?.rows, 2)
        XCTAssertTrue(save(text).contains("| Design | $49 |"), save(text))
    }
    @MainActor private func imageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 1200, height: 600))
        image.lockFocus()
        NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.30, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
        ("Space for a good idea." as NSString).draw(at: NSPoint(x: 90, y: 300), withAttributes: [.font: MM.Fonts.native(68, .medium), .foregroundColor: NSColor.white])
        ("A simple capture, kept with the conversation." as NSString).draw(at: NSPoint(x: 94, y: 220), withAttributes: [.font: MM.Fonts.native(30, .regular), .foregroundColor: NSColor.white])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor func testImagesAreOwnedPortableAndPreviewable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = DocumentAssets(root: root.appendingPathComponent("assets"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Screenshot.png")
        let data = try imageData(); try data.write(to: original)
        let target = try assets.importImage(at: original, documentID: "note-source")
        try FileManager.default.removeItem(at: original)
        let owned = try XCTUnwrap(assets.resolve(target))
        XCTAssertEqual(try Data(contentsOf: owned), data)
        let markdown = "Title\n![Screenshot](\(target))\n"
        XCTAssertEqual(MarkdownRich.markdown(from: MarkdownRich.attributed(from: markdown, assets: assets)), markdown)
        let copied = try assets.adoptingImages(in: markdown, documentID: "note-test")
        XCTAssertTrue(copied.contains("../assets/note-test/"))
        XCTAssertEqual(assets.ownedFiles(documentID: "note-test").count, 1)
        try FileManager.default.removeItem(at: owned)
        let (window, text) = try await host(copied, assets: assets)
        defer { window.contentView = nil; window.close(); DocumentImagePreview.shared.close() }
        let attachment = try XCTUnwrap(text.attributedString().attribute(.attachment, at: 6, effectiveRange: nil) as? DocumentImageAttachment)
        XCTAssertGreaterThan(attachment.image?.size.width ?? 0, 100)
        DocumentImagePreview.shared.open(attachment.sourceURL, fullScreen: false)
        XCTAssertTrue(NSApp.windows.contains { $0 is ImagePreviewWindow && $0.isVisible })
        DocumentImagePreview.shared.close()
        XCTAssertNil(assets.resolve("../assets/../../private.txt"))
        XCTAssertNil(assets.resolve("file:///private/image.png"))
        XCTAssertThrowsError(try assets.importImage(data: Data("not an image".utf8), documentID: "note-test"))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(data, forType: .png)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.paste(from: board)
        XCTAssertEqual(assets.ownedFiles(documentID: "note-test").count, 2)
        let saved = save(text)
        XCTAssertEqual(MarkdownRich.markdown(from: MarkdownRich.attributed(from: saved, assets: assets)), saved)
    }
    @MainActor func testDraggingImageIntoDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Capture.png")
        try imageData().write(to: file)
        let assets = DocumentAssets(root: root.appendingPathComponent("assets"))
        let (window, text) = try await host("Title\nA thought\n", assets: assets)
        defer { window.contentView = nil; window.close() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let drag = ImageDrag(board: board, window: window, location: text.convert(NSPoint(x: 90, y: 120), to: nil))
        XCTAssertEqual(text.draggingEntered(drag), .copy)
        XCTAssertEqual(text.draggingUpdated(drag), .copy)
        XCTAssertNotNil(text.imageDropLocation)
        XCTAssertTrue(text.prepareForDragOperation(drag))
        XCTAssertTrue(text.performDragOperation(drag))
        XCTAssertNil(text.imageDropLocation)
        XCTAssertTrue(save(text).contains("![Capture](../assets/note-test/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(assets.ownedFiles(documentID: "note-test").count, 1)
        let withImage = save(text)
        text.undoManager?.undo(); XCTAssertFalse(save(text).contains("![Capture]"))
        text.undoManager?.redo(); XCTAssertEqual(save(text), withImage)
    }
    @MainActor func testRenderImagesAndTables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = DocumentAssets(root: root)
        let target = try assets.importImage(data: imageData(), documentID: "note-test")
        let source = "Room to think\nA few things worth keeping together.\n\n![An idea](\(target))\n\n## A little clarity\n| Next step | Owner |\n| --- | --- |\n| Explore the first sketch | Jamie |\n| **Share the direction** | Alex |\n\n- Keep it simple\n- Make room for the next idea"
        for dark in [false, true] {
          for width: CGFloat in [560, 820] {
            let (window, text) = try await host(source, assets: assets)
            window.setContentSize(NSSize(width: width, height: 900))
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            text.enforceTitleStyling()
            try await Task.sleep(for: .milliseconds(200))
            var attachmentCount = 0
            text.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.attributedString().length)) { value, _, _ in
                if let attachment = value as? DocumentImageAttachment {
                    attachmentCount += 1
                    XCTAssertGreaterThan(attachment.image?.size.width ?? 0, 100)
                }
            }
            XCTAssertEqual(attachmentCount, 1)
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-blocks-\(dark ? "dark" : "light")-\(Int(width)).png"))
            XCTAssertEqual(save(text), source)
          }
        }
    }
}

@MainActor private final class ImageDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, window: NSWindow, location: NSPoint) {
        draggingPasteboard = board; draggingDestinationWindow = window; draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
