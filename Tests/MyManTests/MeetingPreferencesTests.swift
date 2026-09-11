import XCTest
import AppKit
import SwiftUI
@testable import MyMan

final class MeetingPreferencesTests: XCTestCase {
    @MainActor func testRenderVocabularyAndReversiblePeopleControls() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let people = [
            Person(id: "one", name: "Jamie Lee", email: "jamie@example.com", meetCount: 3, firstMetAt: Date(), lastMetAt: Date()),
            Person(id: "two", name: "Alex Morgan", email: "alex@example.com", meetCount: 1, firstMetAt: Date(), lastMetAt: Date(), hidden: true)
        ]
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView:
                MeetingVocabularyControls(suggestions: ["StoneBot", "Northwind"], people: people,
                    accept: { _ in }, dismiss: { _ in }, togglePerson: { _ in }, peopleExpanded: true)
                    .padding(MM.Layout.paddingLarge).frame(width: 420, height: 330, alignment: .topLeading)
                    .background(MM.Colors.background))
            try await Task.sleep(for: .milliseconds(200))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-meeting-preferences-\(dark ? "dark" : "light").png"))
        }
    }
}
