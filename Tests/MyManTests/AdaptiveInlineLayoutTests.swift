import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class AdaptiveInlineLayoutTests: XCTestCase {
    @MainActor func testNativeInlineTasksAndCalendar() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] else { throw XCTSkip("Opt-in native layout review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let tasks = ["Review the launch checklist", "Send the updated mockups"].enumerated().map {
            TaskItem(id: "fixture-\($0.offset)", title: $0.element, source: "manual", done: false,
                     createdAt: .now, completedAt: nil)
        }
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(10 * 3_600)
        let events = ["Design review", "Project catch-up"].enumerated().map {
            CalendarPanelView.EventLite(id: "event-\($0.offset)", start: start.addingTimeInterval(Double($0.offset) * 7_200),
                end: start.addingTimeInterval(Double($0.offset) * 7_200 + 1_800), title: $0.element,
                notes: "", attendeeNames: [], meetingID: nil, googleURL: nil)
        }
        let days = (0..<7).map { index in
            CalendarPanelView.DayEvents(id: "day-\(index)", date: Calendar.current.date(byAdding: .day, value: index, to: start)!,
                                       events: index == 0 ? events : [])
        }
        func calendar(_ list: [CalendarPanelView.DayEvents], permission: Bool = false) -> AnyView {
            AnyView(InlineCalendarView(days: list, needsAccessRequest: permission, accessDenied: false, onAccess: {}) {
                CalendarEventCard(event: $0, onOpen: {}, onJoin: {}, onBrief: {}, onNotes: {}, inline: true)
            })
        }
        for scheme in [ColorScheme.dark, .light] {
            for (name, content) in [
                ("tasks-empty", AnyView(InlineTasksView(tasks: []))), ("tasks", AnyView(InlineTasksView(tasks: tasks))),
                ("calendar", calendar(days)), ("calendar-empty", calendar(days.map { .init(id: $0.id, date: $0.date, events: []) })),
                ("calendar-permission", calendar([], permission: true))
            ] {
                let host = NSHostingView(rootView: content.frame(width: MM.Layout.panelWidth)
                    .fixedSize(horizontal: false, vertical: true).background(MM.Colors.background).preferredColorScheme(scheme))
                host.frame = NSRect(x: 0, y: 0, width: MM.Layout.panelWidth, height: 400)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, MM.Layout.panelWidth)
                XCTAssertLessThan(host.bounds.height, name == "calendar" ? 360 : 220)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
