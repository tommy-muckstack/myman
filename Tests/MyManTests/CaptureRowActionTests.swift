import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class CaptureRowActionTests: XCTestCase {
    @MainActor func testOptInHoverCopyClickDoesNotOpenTheCapture() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_VERIFY_CAPTURE_ROW_CLICK"] == "enabled" else { throw XCTSkip("Opt-in native mouse verification") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let board = NSPasteboard.general
        let previousItems = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let capture = item("note")
        var opens = 0
        let window = FloatingPanel(content: CaptureResultRow(match: .init(item: capture, tier: 0, score: 0,
            excerpt: capture.body, reason: "Note", matchedTerms: []), onOpen: { opens += 1 }).preferredColorScheme(.dark), fixedSize: true)
        window.setFrame(NSRect(x: 150, y: 150, width: 620, height: 130), display: false)
        window.title = "MyMan synthetic hover-action verification"
        window.isReleasedWhenClosed = false; window.dismissesOnResign = false
        let host = try XCTUnwrap(window.contentView)
        defer {
            window.close()
            if board.string(forType: .string) == capture.body { board.clearContents(); board.writeObjects(previousItems) }
            previousApp?.activate(options: [.activateIgnoringOtherApps])
        }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        func pumpEvents() {
            // XCTest runs the main run loop without NSApplication.run().
            for _ in 0..<100 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        pumpEvents()
        let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        func mouse(_ type: CGEventType, at point: CGPoint) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: point.x, y: screenTop - point.y), mouseButton: .left))
            event.post(tap: .cgSessionEventTap)
        }
        try mouse(.mouseMoved, at: CGPoint(x: window.frame.midX, y: window.frame.midY))
        try await Task.sleep(for: .milliseconds(300))
        pumpEvents()
        try await Task.sleep(for: .milliseconds(100))
        // The fixture has a fixed 620pt row and 32pt action targets. Click
        // the visible Copy target through the event system, not its callback.
        let point = NSPoint(x: host.bounds.maxX - 100,
                            y: host.isFlipped ? 26 : host.bounds.maxY - 26)
        let center = window.convertPoint(toScreen: host.convert(point, to: nil))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/myman-hover-click.png"))
        }
        try mouse(.mouseMoved, at: center)
        try mouse(.leftMouseDown, at: center)
        try mouse(.leftMouseUp, at: center)
        try await Task.sleep(for: .milliseconds(300))
        pumpEvents()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(board.string(forType: .string), capture.body)
        XCTAssertEqual(opens, 0, "Clicking Copy must not activate the row's Open action")
    }

    private func item(_ kind: String, path: String = "", body: String = "Synthetic capture text") -> CaptureItem {
        CaptureItem(id: kind + "-fixture", kind: kind, sourceID: "12345678-1234-1234-1234-123456789ABC",
                    rawTitle: "Project review with the design and engineering teams", generatedTitle: "", userTitle: "", body: body,
                    summary: "Synthetic meeting summary", metadata: "", sourcePath: path,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000), modifiedAt: Date(),
                    pinned: false, excluded: false, revision: 1)
    }

    @MainActor func testCopyPreservesMediaAndTextTypesAndDoesNotEraseClipboardOnMissingContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let path = root.appendingPathComponent("synthetic image.png")
        try AgentImages.png(image).write(to: path)
        XCTAssertTrue(CaptureActions.copy(item("screenshot", path: path.path), pasteboard: board))
        XCTAssertNotNil(NSImage(pasteboard: board), "Screenshot Copy must put image data on the clipboard")
        XCTAssertTrue(CaptureActions.copy(item("screenshot", path: path.path), textOnly: true, pasteboard: board))
        XCTAssertEqual(board.string(forType: .string), "Synthetic capture text")

        let movie = root.appendingPathComponent("synthetic recording.mov")
        try Data("fixture".utf8).write(to: movie)
        XCTAssertTrue(CaptureActions.copy(item("recording", path: movie.path), pasteboard: board))
        XCTAssertEqual((board.readObjects(forClasses: [NSURL.self])?.first as? URL)?.path, movie.path)
        for kind in ["note", "meeting", "dictation"] {
            XCTAssertTrue(CaptureActions.copy(item(kind), pasteboard: board))
            XCTAssertEqual(board.string(forType: .string), "Synthetic capture text")
        }
        XCTAssertFalse(CaptureActions.copy(item("screenshot", path: root.appendingPathComponent("missing.png").path), pasteboard: board))
        XCTAssertEqual(board.string(forType: .string), "Synthetic capture text")
        XCTAssertFalse(CaptureActions.copy(item("recording", path: ""), pasteboard: board))
        XCTAssertEqual(board.string(forType: .string), "Synthetic capture text")
    }

    @MainActor func testCopyPathUsesOriginalMediaAndExistingBrainDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        for kind in ["note", "meeting", "dictation", "screenshot", "recording"] {
            let media = root.appendingPathComponent("Media folder/café \(kind).file")
            let capture = item(kind, path: media.path)
            let url = try XCTUnwrap(CaptureActions.fileURL(for: capture, brainRoot: root))
            if ["screenshot", "recording"].contains(kind) { XCTAssertEqual(url.path, media.path) }
            else { XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, kind == "dictation" ? "dictations" : kind + "s") }
            board.clearContents(); board.setString("Preserve existing clipboard", forType: .string)
            XCTAssertFalse(CaptureActions.copyPath(capture, brainRoot: root, pasteboard: board))
            XCTAssertEqual(board.string(forType: .string), "Preserve existing clipboard")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            XCTAssertTrue(CaptureActions.copyPath(capture, brainRoot: root, pasteboard: board))
            XCTAssertEqual(board.string(forType: .string), url.path)
        }
    }

    @MainActor func testRenderHoverActions() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let captures = [item("screenshot"), item("note"), item("meeting"), item("recording")]
        for scheme in [ColorScheme.dark, .light] {
            let content = VStack(spacing: 3) {
                ForEach(captures) { capture in
                    CaptureResultRow(match: .init(item: capture, tier: 0, score: 0,
                        excerpt: "Review the mockups and follow up on the project timeline.", reason: capture.kind.capitalized, matchedTerms: []),
                        selected: true, keyboardFocused: true)
                }
            }.padding(8).background(MM.Colors.background).preferredColorScheme(scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 620, height: 500)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("capture-actions-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
