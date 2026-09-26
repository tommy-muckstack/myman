import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class AdaptiveInlineLayoutTests: XCTestCase {
    @MainActor func testNativeInlineTasksAndCalendar() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] else { throw XCTSkip("Opt-in native layout review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let tasks = ["Review the launch checklist", "Send the updated mockups"].enumerated().map {
            TaskItem(id: "fixture-\($0.offset)", title: $0.element, source: "manual", done: false,
                     createdAt: .now, completedAt: nil)
        }
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(10 * 3_600)
        let events: [CalendarPanelView.EventLite] = ["Design review", "Project catch-up"].enumerated().map { index, title in
            let beginning = start.addingTimeInterval(Double(index) * 7_200)
            let attendees: [String] = index == 0 ? ["Alex", "Casey"] : []
            let joinURL: URL? = index == 0 ? URL(string: "https://meet.google.com/fixture") : nil
            return CalendarPanelView.EventLite(id: "event-\(index)", start: beginning,
                end: beginning.addingTimeInterval(1_800), title: title,
                notes: "", attendeeNames: attendees, joinURL: joinURL, meetingID: nil, googleURL: nil)
        }
        let days: [CalendarPanelView.DayEvents] = (0..<7).map { index in
            CalendarPanelView.DayEvents(id: "day-\(index)", date: Calendar.current.date(byAdding: .day, value: index, to: start)!,
                                       events: index == 0 ? events : [])
        }
        func calendar(_ list: [CalendarPanelView.DayEvents], permission: Bool = false, request: LauncherCalendarRequest = .today) -> AnyView {
            AnyView(InlineCalendarView(days: list, needsAccessRequest: permission, accessDenied: false, onAccess: {}, request: request) {
                CalendarEventCard(event: $0, onOpen: {}, onJoin: {}, onBrief: {}, onNotes: {}, inline: true)
            })
        }
        for scheme in [ColorScheme.dark, .light] {
            let fixtures: [(String, AnyView)] = [
                ("tasks-empty", AnyView(InlineTasksView(tasks: []))), ("tasks", AnyView(InlineTasksView(tasks: tasks))),
                ("calendar", calendar(days)), ("calendar-empty", calendar(days.map { .init(id: $0.id, date: $0.date, events: []) })),
                ("calendar-permission", calendar([], permission: true)),
                ("calendar-tomorrow", calendar(days, request: .tomorrow)),
                ("calendar-week", calendar(days, request: .week))
            ]
            for (name, content) in fixtures {
                let host = NSHostingView(rootView: content.frame(width: MM.Layout.panelWidth)
                    .fixedSize(horizontal: false, vertical: true).background(MM.Colors.background).preferredColorScheme(scheme))
                let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MM.Layout.panelWidth, height: 400),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                host.appearance = appearance
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: MM.Layout.panelWidth, height: 400)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, MM.Layout.panelWidth)
                XCTAssertLessThan(host.bounds.height, ["calendar", "calendar-week"].contains(name) ? 380 : 240)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                let background = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
                if scheme == .light { XCTAssertGreaterThan(background.redComponent, 0.8) }
                else { XCTAssertLessThan(background.redComponent, 0.2) }
                window.contentView = nil
                window.close()
            }
        }
    }
}
