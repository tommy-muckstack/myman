import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class QuickReminderTests: XCTestCase {
    @MainActor func testNativeWidgetExpandsWithoutTakingFocusAndDismisses() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { throw XCTSkip("Opt-in native widget verification") }
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let timer = QuickToolsModel()
        timer.onFinish = {}
        let controller = QuickActivityWidgetController(timer: timer, reminders: store)
        defer { controller.stop(); timer.stop() }
        let keyWindow = NSApp.keyWindow
        controller.start()
        timer.start(seconds: 600)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "myman.quick-activity" && $0.isVisible })
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertEqual(panel.frame.width, 178)
        controller.hover(true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.frame.width, 340)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        controller.setExpanded(false)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.frame.width, 178)
        timer.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible)
    }

    func testNaturalLanguageReminderMessagesAndTimes() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
        for input in ["reminder in 10m for taking pizza out", "remind me to take pizza out in 10 minutes",
                      "reminder take pizza out in 10m"] {
            let draft = try XCTUnwrap(ReminderDraft.parse(input, now: now))
            XCTAssertEqual(draft.date.timeIntervalSince(now), 600)
            XCTAssertTrue(draft.title.contains("pizza out"))
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .create)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tomorrow = try XCTUnwrap(ReminderDraft.parse("remind me to call Sam tomorrow at 9:30am", now: now, calendar: calendar))
        XCTAssertEqual(tomorrow.title, "call Sam")
        XCTAssertEqual(tomorrow.date, ISO8601DateFormatter().date(from: "2026-09-24T09:30:00Z"))
        XCTAssertEqual(ReminderDraft.parse("reminder", now: now)?.title, "")
        XCTAssertNil(ReminderDraft.parse("find reminder"))
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find reminder in 10m for pizza"), .search)
    }

    @MainActor func testPersistenceDueOnlyOnceAndCancellation() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        var alarms = 0
        var cancelled: [String] = []
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { cancelled.append($0) }, alert: { alarms += 1 })
        let now = Date()
        _ = await store.add(.init(title: "Take pizza out", date: now.addingTimeInterval(600)), now: now)
        let restored = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        XCTAssertEqual(restored.reminders, store.reminders)
        store.tick(now: now.addingTimeInterval(601))
        store.tick(now: now.addingTimeInterval(602))
        XCTAssertEqual(alarms, 1)
        let id = try XCTUnwrap(store.reminders.first?.id)
        store.dismiss(id)
        XCTAssertTrue(store.reminders.isEmpty)
        XCTAssertEqual(cancelled, ["myman.reminder." + id.uuidString])
        _ = await store.add(.init(title: "", date: now.addingTimeInterval(600)), now: now)
        _ = await store.add(.init(title: "Past", date: now.addingTimeInterval(-1)), now: now)
        XCTAssertTrue(store.reminders.isEmpty)
    }

    @MainActor func testDismissWhileNotificationPermissionIsPendingCancelsLateSchedule() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelled: [String] = []
        let store = ReminderStore(defaults: defaults, schedule: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, cancelNotification: { cancelled.append($0) }, alert: {})
        let task = Task { await store.add(.init(title: "Pizza", date: Date().addingTimeInterval(600))) }
        while continuation == nil { await Task.yield() }
        let id = try XCTUnwrap(store.reminders.first?.id)
        store.dismiss(id)
        continuation?.resume(returning: true)
        _ = await task.value
        XCTAssertTrue(store.reminders.isEmpty)
        XCTAssertEqual(cancelled.count, 2)
    }

    @MainActor func testWidgetCountdownExpansionAndMeetingAvoidance() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        let store = ReminderStore(defaults: defaults, schedule: { _ in true }, cancelNotification: { _ in }, alert: {})
        _ = await store.add(.init(title: "Take pizza out", date: Date().addingTimeInterval(600)))
        let timer = QuickToolsModel()
        timer.onFinish = {}
        let controller = QuickActivityWidgetController(timer: timer, reminders: store)
        XCTAssertEqual(controller.count, 1)
        XCTAssertFalse(controller.showsTimer)
        XCTAssertEqual(controller.countdown, "10:00")
        timer.start(seconds: 120)
        defer { timer.stop() }
        XCTAssertTrue(controller.showsTimer)
        XCTAssertEqual(controller.count, 2)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let meeting = NSRect(x: 900, y: 550, width: 516, height: 326)
        for expanded in [false, true] {
            controller.setExpanded(expanded)
            let frame = QuickActivityWidgetController.frame(size: controller.size, visible: visible, avoiding: meeting)
            XCTAssertFalse(frame.intersects(meeting))
            XCTAssertTrue(visible.contains(frame))
            for dark in [false, true] {
                let host = NSHostingView(rootView: QuickActivityWidget(controller: controller).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: controller.size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: "/private/tmp/myman-simple-review")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("widget-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light").png"))
            }
        }
        XCTAssertEqual(QuickActivityWidgetController.time(3661), "1:01:01")
        XCTAssertEqual(QuickActivityWidgetController.time(-1), "00:00")
    }
}
