import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import MyMan

final class MeetingReminderUXTests: XCTestCase {
    @MainActor func testReminderFallsBackToAppChimeWhenNotificationSoundIsDisabled() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var sounds = 0
        let store = ReminderStore(defaults: preferences, schedule: { _ in true }, cancelNotification: { _ in },
                                  alert: { sounds += 1 }, notificationSoundsEnabled: { false })
        let due = Date().addingTimeInterval(60)
        _ = try await store.create(.init(title: "Check the oven", date: due))
        store.tick(now: due)
        for _ in 0..<100 where sounds == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sounds, 1)
        store.tick(now: due.addingTimeInterval(1))
        XCTAssertEqual(sounds, 1)
    }

    @MainActor func testRealTimerCompletionStartsBundledAudio() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_SOUND_REVIEW"] == "1" else {
            throw XCTSkip("Opt-in audible completion check")
        }
        let timer = QuickToolsModel()
        defer { timer.stop() }
        timer.start(seconds: 1)
        for _ in 0..<150 where !timer.finished { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(timer.finished)
        XCTAssertTrue(QuickCompletionSound.isPlaying, "The real timer starts retained audio playback")
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(QuickCompletionSound.isPlaying)
    }

    @MainActor func testReminderCanBeDismissedAndReplacedWhileNotificationPermissionIsPending() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var permission: CheckedContinuation<Bool, Never>?
        var requests = 0
        var cancelled: [String] = []
        let store = ReminderStore(defaults: preferences, schedule: { _ in
            requests += 1
            if requests == 1 { return await withCheckedContinuation { permission = $0 } }
            return true
        }, cancelNotification: { cancelled.append($0) }, alert: {})
        let model = QuickToolsModel()
        let saved = expectation(description: "Local creation finishes before notification permission")
        let creation = Task {
            let result = await model.startActivity(.reminder(.init(title: "Take pizza out", date: Date().addingTimeInterval(600))), reminders: store)
            saved.fulfill()
            return result
        }
        await fulfillment(of: [saved], timeout: 2)
        for _ in 0..<100 where permission == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(permission)
        XCTAssertFalse(model.startingActivity)
        let first = try XCTUnwrap(store.reminders.first)
        store.dismiss(first.id)
        let replacement = await model.startActivity(.reminder(.init(title: "Check the oven", date: Date().addingTimeInterval(900))), reminders: store)
        XCTAssertTrue(replacement)
        XCTAssertFalse(model.startingActivity)
        XCTAssertEqual(store.reminders.map(\.title), ["Check the oven"])
        XCTAssertTrue(cancelled.contains(first.notificationID))
        let succeeded = await creation.value
        XCTAssertTrue(succeeded)
        pending.resume(returning: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.reminders.map(\.title), ["Check the oven"], "Late authorization cannot resurrect a dismissed reminder")
    }

    func testLegacyListeningPauseMigratesToPersistentChoice() throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 100)
        preferences.set(200.0, forKey: AdaptiveListeningPreference.legacyPauseKey)
        XCTAssertFalse(AdaptiveListeningPreference.isEnabled(in: preferences, now: now))
        XCTAssertFalse(AdaptiveListeningPreference.isEnabled(in: preferences, now: now.addingTimeInterval(86_400)))
        XCTAssertNil(preferences.object(forKey: AdaptiveListeningPreference.legacyPauseKey))
        AdaptiveListeningPreference.setEnabled(true, in: preferences)
        XCTAssertTrue(AdaptiveListeningPreference.isEnabled(in: preferences))
    }

    @MainActor func testNativeMeetingAndReminderReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_MEETING_UI_REVIEW"] else {
            throw XCTSkip("Opt-in native meeting/reminder UI review")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: "meeting-ui-fixture", title: "Planning the next release", startedAt: Date().addingTimeInterval(-3600), endedAt: Date(),
                              transcript: "**Alex** [0:00]: Let’s make reminder scheduling easier.\n\n**You** [0:12]: We’ll review the calendar and time controls together.",
                              summary: "## Summary\nThe team reviewed reminder scheduling and the next release.\n\n## Next steps\n- Review the calendar and time controls.")
        var note = Note(body: "My follow-up questions\n- Can we make the date picker easier to click?\n- Verify the reminder sound controls.")
        note.meetingID = meeting.id
        let linkedNote = note
        try await db.write { db in
            try meeting.insert(db)
            try linkedNote.insert(db)
            for (id, title) in [("design", "Product design"), ("reminders", "Reminders and scheduling"), ("release", "Release planning"), ("access", "Accessibility and interaction")] {
                try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES(?,?,?)", arguments: [id, title, id])
                try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES(?,?)", arguments: [id, "meeting-" + meeting.id])
            }
        }
        XCTAssertEqual(try ThemeStore.list(itemID: "meeting-" + meeting.id, database: db).count, 4)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: MeetingDocumentView(meeting: meeting, database: db, automaticallySummarize: false).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, folder: folder, name: "meeting-summary")
        try click(window, x: 225, top: 179)
        try await Task.sleep(for: .milliseconds(150))
        try capture(window, folder: folder, name: "meeting-notes")
        try click(window, x: 80, top: 179)
        try await Task.sleep(for: .milliseconds(150))
        try capture(window, folder: folder, name: "meeting-transcript")

        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = ReminderStore(defaults: preferences, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let model = QuickToolsModel()
        let due = Date().addingTimeInterval(1800)
        window.setContentSize(NSSize(width: 620, height: 235))
        window.contentView = NSHostingView(rootView: QuickReminderInput(model: model, draft: .init(title: "Take pizza out of the oven", date: due), onTyping: {}, onStarted: {}, reminders: store)
            .padding(MM.Layout.padding).background(MM.Colors.background).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(100))
        try capture(window, folder: folder, name: "reminder-picker")
        try click(window, x: 130, top: 114)
        try await Task.sleep(for: .milliseconds(200))
        if let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            try capture(popover, folder: folder, name: "reminder-calendar")
            popover.orderOut(nil)
        } else { XCTFail("Date button opens the calendar") }
        window.setContentSize(NSSize(width: 300, height: 290))
        window.contentView = NSHostingView(rootView: ReminderTimePicker(date: .constant(due), onDone: {}).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(100))
        try capture(window, folder: folder, name: "reminder-time")
        _ = try await store.create(.init(title: "Take pizza out of the oven", date: due))
        let controller = QuickActivityWidgetController(timer: model, reminders: store)
        controller.setExpanded(true)
        window.setContentSize(controller.size)
        window.contentView = NSHostingView(rootView: QuickActivityWidget(controller: controller).preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(100))
        try capture(window, folder: folder, name: "reminder-widget")
    }

    @MainActor private func click(_ window: NSWindow, x: CGFloat, top: CGFloat) throws {
        let host = try XCTUnwrap(window.contentView)
        let point = NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    @MainActor private func capture(_ window: NSWindow, folder: String, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}
