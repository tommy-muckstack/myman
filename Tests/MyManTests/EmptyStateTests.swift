import AppKit
import SwiftUI
import XCTest
import GRDB
@testable import MyMan

final class EmptyStateTests: XCTestCase {
    @MainActor func testNativeEmptySurfacesAndBlankEditorRemainsEditable() async throws {
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        func render<V: View>(_ view: V, name: String, size: CGSize) async throws {
            let panel = FloatingPanel(content: view.frame(width: size.width, height: size.height).background(MM.Colors.background), fixedSize: true)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.setFrame(NSRect(origin: .zero, size: size), display: false)
            defer { panel.contentView = nil; panel.close() }
            let host = try XCTUnwrap(panel.contentView); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-empty-\(name).png"))
            XCTAssertEqual(host.bounds.size, size)
        }
        let small = CGSize(width: 300, height: 370)
        try await render(CalendarEmptyState(needsAccessRequest: true, accessDenied: false), name: "calendar", size: small)
        try await render(UtilityEmptyState(icon: .addBox, title: "Nothing on your plate", message: "A little room to breathe.", actionTitle: "Add a task"), name: "tasks", size: CGSize(width: 260, height: 370))
        try await render(UtilityEmptyState(icon: .related, title: "Ideas find each other", message: "Related captures will gather here."), name: "themes", size: CGSize(width: 620, height: 400))
        let queue = try DatabaseQueue(); try Database.migrator.migrate(queue)
        let model = CaptureLibraryModel(database: queue)
        try await render(CaptureLibraryView(query: .constant(""), mode: .constant(.search), model: model), name: "search", size: CGSize(width: 620, height: 440))
        let actions: [LauncherAction] = [(MMIcon.screenshot, "Take Screenshot"), (.note, "New Note"), (.voice, "Voice Dictation"), (.calendar, "Record Meeting"), (.recordScreen, "Record Screen")].enumerated().map { index, item in LauncherAction(id: String(index), icon: item.0, title: item.1, hint: nil, enabled: true, run: {}) }
        try await render(LauncherView(actions: actions, onOpenNote: { _ in }, onOpenScreenshot: { _ in }, onSaveQueryAsNote: { _ in }, onOpenChat: {}, onDismiss: {}, libraryModel: model), name: "launcher", size: CGSize(width: 620, height: 590))
        model.cancel()
        try await render(UtilityEmptyState(icon: .related, title: "Connections take shape", message: "Related captures will show up here.", compact: true), name: "related", size: CGSize(width: 560, height: 170))
        let session = RichEditorSession()
        var body = ""
        let view = RichMarkdownEditor(markdown: Binding(get: { body }, set: { body = $0 }), session: session, showsEmptyPlaceholder: false)
            .overlay { UtilityEmptyState(icon: .note, title: "Room for a thought", message: "Start typing, or drop something in.").allowsHitTesting(false) }
        try await render(view, name: "note", size: CGSize(width: 640, height: 500))
        // The centered invitation is decorative; the underlying native editor
        // must keep normal typing, paste, and formatting behavior.
        let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 640, height: 500); host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(session.textView)
        XCTAssertFalse(text.showsEmptyPlaceholder)
        text.insertText("A thought worth keeping", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(body, "A thought worth keeping")
    }
}
