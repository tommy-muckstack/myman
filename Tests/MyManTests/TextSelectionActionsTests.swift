import XCTest
import AppKit
import SwiftUI
@testable import MyMan

final class TextSelectionActionsTests: XCTestCase {
    // XCTest may run without an active application (including CI). Model the
    // source window's key state without taking focus from the user's app.
    private final class SelectionWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    func testSelectionUsesUTF16AndPreservesExactSource() {
        let text = "Alex: 👩🏽‍💻 said ‘not approved’.\nNext topic"
        let range = (text as NSString).range(of: "👩🏽‍💻 said ‘not approved’.")
        XCTAssertEqual(TextSelectionSnapshot.text(in: text, range: range), "👩🏽‍💻 said ‘not approved’.")
        XCTAssertEqual(TextSelectionSnapshot.text(in: "  quoted  ", range: NSRange(location: 0, length: 10)), "  quoted  ")
    }

    func testStaleEmptyAndBrokenUnicodeRangesHaveNoActionText() {
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0),
                      NSRange(location: 3, length: 100), NSRange(location: Int.max - 1, length: 10),
                      NSRange(location: -1, length: 2)] {
            XCTAssertNil(TextSelectionSnapshot.text(in: "abc", range: range))
        }
        XCTAssertNil(TextSelectionSnapshot.text(in: "😀", range: NSRange(location: 0, length: 1)))
        XCTAssertNil(TextSelectionSnapshot.text(in: " \n ", range: NSRange(location: 0, length: 3)))
    }

    @MainActor
    func testLargeSelectionIsRejectedWithoutTruncatingOrChangingSource() {
        let source = String(repeating: "é", count: 4_001)
        let model = SelectedTextResultModel(action: .summarize, source: source)
        model.start()
        XCTAssertFalse(model.working)
        XCTAssertEqual(model.source, source)
        XCTAssertTrue(model.result.isEmpty)
        XCTAssertEqual(model.message, "Select a shorter passage to use this action.")
    }

    @MainActor
    func testNativeReadingTextWrapsWithoutLosingSelection() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let source = "Alex: The launch is not approved yet. We need Maya’s review before Friday. Keep the original transcript unchanged."
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SelectionTextBlock(text: source).frame(width: 260))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> SelectionActionTextView? {
            (view as? SelectionActionTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host))
        XCTAssertGreaterThan(text.frame.height, 40)
        XCTAssertLessThan(text.frame.height, 250)
        let selection = (source as NSString).range(of: "not approved yet")
        text.setSelectedRange(selection)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(text.string, source)
        XCTAssertFalse(text.isEditable)
    }

    @MainActor
    func testToolbarDoesNotTakeKeyboardFocusAndDismissesWithSelection() async throws {
        _ = NSApplication.shared
        let window = SelectionWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        text.string = "Keep the original transcript."
        window.contentView = text
        let toolbar = SelectionToolbarController(textView: text)
        defer { toolbar.hide(); window.contentView = nil; window.close() }
        window.makeFirstResponder(text)
        try await Task.sleep(for: .milliseconds(100))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        toolbar.selectionChanged()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertFalse(text.firstRect(forCharacterRange: text.selectedRange(), actualRange: nil).isEmpty)
        let panel = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(text.string, "Keep the original transcript.")
        if let path = ProcessInfo.processInfo.environment["MYMAN_SELECTION_TOOLBAR_RENDER"],
           let content = panel.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        text.setSelectedRange(NSRange(location: 0, length: 0))
        toolbar.selectionChanged()
        XCTAssertFalse(panel.isVisible)
        text.setSelectedRange(NSRange(location: 0, length: 4))
        toolbar.selectionChanged()
        XCTAssertTrue(panel.isVisible)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(panel.isVisible)
    }
}
