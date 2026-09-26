import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class SpokenTimerTests: XCTestCase {
    @MainActor func testQuickToolsStaysInsideLauncherAndSelectsCalculator() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] else { throw XCTSkip("Opt-in native quick tools verification") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        var openedWindows = 0, dismissals = 0
        var size = NSSize(width: 620, height: 180)
        let model = QuickToolsModel()
        let action = LauncherAction(id: "quick_tools", icon: .agent, title: "Quick Tools", hint: nil, enabled: true) { openedWindows += 1 }
        let shortcuts: [(String, MMIcon, String, String)] = [
            ("screenshot", .screenshot, "Take Screenshot", "⌥S"), ("note", .note, "New Note", "⌥N"),
            ("voice", .voice, "Voice Dictation", "⌥V"), ("meeting", .calendar, "Record Meeting", "⌥M"),
            ("record", .recordScreen, "Record Screen", "⌥R")]
        let actions = shortcuts.map { id, icon, title, hint in LauncherAction(id: id, icon: icon, title: title, hint: hint, enabled: true) {} } + [action]
        let panel = FloatingPanel(content: AdaptiveLauncherView(actions: actions,
            onSaveQueryAsNote: { _ in }, onDismiss: { dismissals += 1 }, onSizeChange: { size = $0 }, tools: model)
            .preferredColorScheme(.dark), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.dismissesOnResign = false
        panel.setContentSize(size)
        defer { panel.contentView = nil; panel.close() }
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        panel.setContentSize(size)
        let host = try XCTUnwrap(panel.contentView)
        func click(_ x: CGFloat, _ top: CGFloat) throws {
            let point = NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }
        let collapsedHeight = size.height
        try click(565, 100)
        try await Task.sleep(for: .milliseconds(200))
        panel.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(size.height, collapsedHeight + 200, "All eight tools expand under the shortcut")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("quick-tools-inline.png"))
        try click(200, 171)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.tool, .calculator)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(openedWindows, 0)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(QuickToolShortcut.all.count, 8)
    }

    @MainActor func testTypedSetTimerForFiveMinutesSubmitsWithReturn() async throws {
        for input in ["set timer for 5m", "timer 5m", "set a timer for 5 minutes", "start timer for five minutes"] {
            XCTAssertEqual(QuickToolParser.parse(input), .timer(300), input)
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .create, input)
        }
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { throw XCTSkip("Opt-in native Return verification") }
        _ = NSApplication.shared
        let model = QuickToolsModel()
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let voice = AdaptiveLauncherVoice(dependencies: .init(authorize: { true }, prepare: { true }, begin: { UUID() },
            end: { _ in [] }, discard: { _ in }, level: { _ in 0 }, transcribe: { _ in "" }),
            automaticallyPoll: false, preferences: preferences)
        var dismissals = 0
        var panel: FloatingPanel!
        panel = FloatingPanel(content: AdaptiveLauncherView(actions: [], voice: voice, onSaveQueryAsNote: { _ in XCTFail("Not a note") },
            onDismiss: { dismissals += 1; panel.orderOut(nil) }, onSizeChange: { _ in }, tools: model), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.dismissesOnResign = false
        panel.setContentSize(NSSize(width: 620, height: 300))
        defer { voice.stop(); model.stop(); panel.contentView = nil; panel.close() }
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try XCTUnwrap(textField(in: try XCTUnwrap(panel.contentView)))
        panel.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let inputX = field.convert(field.bounds, to: panel.contentView).minX
        editor.insertText("set timer for 5m", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.tool, .timer(300))
        XCTAssertEqual(field.convert(field.bounds, to: panel.contentView).minX, inputX, accuracy: 0.5,
                       "Recognition keeps the input aligned with its empty state")
        XCTAssertFalse(model.timerActive, "Typing previews; Return commits")
        let host = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"])
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("typed-timer-clear.png"))
        let point = NSPoint(x: 575, y: host.isFlipped ? 32 : host.bounds.height - 32)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "", "The padded Clear control clears the actual input")
        XCTAssertEqual(voice.phase, .listening, "Clear restarts listening")
        panel.makeFirstResponder(field)
        let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        nextEditor.insertText("set timer for 5m", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        nextEditor.insertNewline(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.timerActive)
        XCTAssertEqual(try XCTUnwrap(model.deadline).timeIntervalSinceNow, 300, accuracy: 1)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testPizzaRequestParsesBothDigitsAndSpokenNumbers() throws {
        let now = Date()
        for input in ["set a timer for 30 seconds to remind me to take a pizza out of the oven",
                      "Set a timer for thirty seconds to remind me to take a pizza out of the oven.",
                      "Please set a timer for thirty seconds for take a pizza out of the oven",
                      "Can you set a reminder in thirty seconds to take a pizza out of the oven?"] {
            let draft = try XCTUnwrap(ReminderDraft.parse(input, now: now), input)
            XCTAssertEqual(draft.title, "take a pizza out of the oven")
            XCTAssertEqual(draft.date.timeIntervalSince(now), 30, accuracy: 0.01)
            XCTAssertTrue(draft.hasExplicitTime)
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .create)
        }
        XCTAssertEqual(QuickToolParser.parse("set a timer for thirty seconds"), .timer(30))
        XCTAssertEqual(QuickToolParser.parse("start a timer for one hour and thirty minutes"), .timer(5400))
        XCTAssertEqual(QuickToolParser.parse("timer for one point five minutes"), .timer(90))
        XCTAssertEqual(QuickToolParser.parse("timer for a minute"), .timer(60))
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find set a timer for thirty seconds"), .search)
        XCTAssertFalse(try XCTUnwrap(ReminderDraft.parse("remind me to take pizza out")).hasExplicitTime)
        for input in ["timer -30 seconds", "timer twenty five hours", "timer thirty seconds and", "timer thirty seconds but don't start it"] {
            if case .timer = QuickToolParser.parse(input) { XCTFail(input) }
        }
    }

    @MainActor func testSpokenPizzaRequestCreatesWidgetAndClosesLauncher() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { throw XCTSkip("Opt-in native voice/widget verification") }
        _ = NSApplication.shared
        var time = 0.0
        var volume: Float = 0.03
        let voice = AdaptiveLauncherVoice(dependencies: .init(authorize: { true }, prepare: { true }, begin: { UUID() },
            end: { _ in Array(repeating: 0.01, count: 16_000) }, discard: { _ in }, level: { _ in volume },
            transcribe: { _ in "Set a timer for thirty seconds to remind me to take a pizza out of the oven." },
            now: { Date(timeIntervalSince1970: time) }), automaticallyPoll: false)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let model = QuickToolsModel()
        let widget = QuickActivityWidgetController(timer: model, reminders: store)
        var dismissals = 0
        var panel: FloatingPanel!
        panel = FloatingPanel(content: AdaptiveLauncherView(actions: [], voice: voice, onSaveQueryAsNote: { _ in XCTFail("Not a note") },
            onDismiss: { dismissals += 1; panel.orderOut(nil) }, onSizeChange: { _ in }, tools: model, reminders: store), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.dismissesOnResign = false
        panel.setContentSize(NSSize(width: 620, height: 240))
        defer { voice.stop(); widget.stop(); model.stop(); panel.contentView = nil; panel.close(); defaults.removeObject(forKey: "localReminders.v1") }
        panel.makeKeyAndOrderFront(nil)
        widget.start()
        voice.start()
        for _ in 0..<200 where voice.phase != .listening { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(voice.phase, .listening)
        for instant in [0.1, 0.2, 0.3] { time = instant; voice.sample() }
        volume = 0
        for instant in [0.4, 1.5] { time = instant; voice.sample() }
        for _ in 0..<300 where store.reminders.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.reminders.count, 1)
        let reminder = try XCTUnwrap(store.reminders.first)
        XCTAssertEqual(reminder.title, "take a pizza out of the oven")
        XCTAssertEqual(reminder.date.timeIntervalSinceNow, 30, accuracy: 2)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(voice.enabled)
        for _ in 0..<200 where !NSApp.windows.contains(where: { $0.identifier?.rawValue == "myman.quick-activity" && $0.isVisible }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let activityPanel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "myman.quick-activity" && $0.isVisible })
        XCTAssertEqual(activityPanel.frame.width, 178)
        let originalPointer = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens[0].frame.maxY
        CGWarpMouseCursorPosition(CGPoint(x: activityPanel.frame.midX, y: screenHeight - activityPanel.frame.midY))
        defer { CGWarpMouseCursorPosition(CGPoint(x: originalPointer.x, y: screenHeight - originalPointer.y)) }
        widget.hover(true)
        for _ in 0..<200 where activityPanel.frame.width != 340 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(activityPanel.frame.width, 340)
        XCTAssertEqual(store.reminders.count, 1, "Rendering must not submit twice")
    }

    @MainActor func testSubmissionIsExplicitAndAddsBesideExistingTimer() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let model = QuickToolsModel()
        defer { model.stop() }
        model.update("timer thirty seconds")
        XCTAssertFalse(model.timerActive)
        let started = await model.startActivity(reminders: store)
        XCTAssertTrue(started)
        let deadline = model.deadline
        let first = try XCTUnwrap(model.timerID)
        let added = await model.startActivity(.timer(600), reminders: store)
        XCTAssertTrue(added)
        XCTAssertEqual(model.timers.count, 2)
        XCTAssertEqual(model.timer(first)?.deadline, deadline, "The first timer is never replaced")
        let incomplete = await model.startActivity(.reminder(try XCTUnwrap(ReminderDraft.parse("remind me to take pizza out"))), reminders: store)
        XCTAssertFalse(incomplete)
        XCTAssertTrue(store.reminders.isEmpty)
    }

    @MainActor func testTimerSoundMuteResumeAndOneShotCompletion() {
        let model = QuickToolsModel()
        var sounds = 0
        model.onFinish = { sounds += 1 }
        let now = Date()
        defer { model.stop() }
        model.start(seconds: 30, now: now)
        model.soundEnabled = false
        model.pause(now: now.addingTimeInterval(10))
        model.start(seconds: model.pausedSeconds!, now: now.addingTimeInterval(10))
        XCTAssertFalse(model.soundEnabled)
        model.tick(now: now.addingTimeInterval(31))
        XCTAssertTrue(model.finished)
        XCTAssertEqual(sounds, 0)
        model.stop()
        model.start(seconds: 30, now: now)
        XCTAssertTrue(model.soundEnabled)
        model.tick(now: now.addingTimeInterval(31))
        model.tick(now: now.addingTimeInterval(32))
        XCTAssertEqual(sounds, 1)
    }

    @MainActor func testReminderMuteUpdatesNotificationAndPersists() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        var scheduledSounds: [Bool] = [], sounds = 0
        let store = ReminderStore(defaults: defaults, schedule: { scheduledSounds.append($0.playsSound); return false }, cancelNotification: { _ in }, alert: { sounds += 1 })
        let due = Date().addingTimeInterval(30)
        let reminder = try await store.create(.init(title: "Pizza", date: due))
        try await store.setSoundEnabled(false, for: reminder.id)
        XCTAssertEqual(scheduledSounds, [true, false])
        let restored = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        XCTAssertEqual(restored.reminders.first?.playsSound, false)
        store.tick(now: due.addingTimeInterval(1))
        XCTAssertEqual(sounds, 0)
        XCTAssertEqual(store.reminders.first?.fired, true)
        // Old persisted reminders have no sound field and must retain their message.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reminder)) as? [String: Any])
        legacy.removeValue(forKey: "soundEnabled")
        let decoded = try JSONDecoder().decode(LocalReminder.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.title, "Pizza")
        XCTAssertTrue(decoded.playsSound)
    }

    @MainActor func testMuteWhileNotificationAuthorizationIsPendingCannotRestoreSound() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        var continuation: CheckedContinuation<Bool, Never>?
        var scheduledSounds: [Bool] = []
        let store = ReminderStore(defaults: defaults, schedule: { reminder in
            scheduledSounds.append(reminder.playsSound)
            if scheduledSounds.count == 1 { return await withCheckedContinuation { continuation = $0 } }
            return true
        }, cancelNotification: { _ in }, alert: {})
        let creation = Task { try await store.create(.init(title: "Pizza", date: Date().addingTimeInterval(30))) }
        while continuation == nil { await Task.yield() }
        let id = try XCTUnwrap(store.reminders.first?.id)
        let mute = Task { try await store.setSoundEnabled(false, for: id) }
        while store.reminders.first?.playsSound != false { await Task.yield() }
        continuation?.resume(returning: true)
        _ = try await creation.value
        _ = try await mute.value
        XCTAssertEqual(scheduledSounds, [true, false])
        XCTAssertEqual(store.reminders.first?.playsSound, false)
        XCTAssertEqual(store.reminders.first?.notificationScheduled, true)
    }
}

final class MultipleTimerTests: XCTestCase {
    @MainActor func testTimersRunIndependentlyAndAlarmClearsWhenLastRingingTimerIsDismissed() throws {
        let model = QuickToolsModel()
        var rings = 0, clears = 0
        model.onFinish = { rings += 1 }
        model.onAlarmCleared = { clears += 1 }
        let now = Date(timeIntervalSince1970: 1000)
        let short = model.addTimer(seconds: 30, now: now)
        let long = model.addTimer(seconds: 600, now: now)
        let muted = model.addTimer(seconds: 30, soundEnabled: false, now: now)
        model.pause(long, now: now.addingTimeInterval(10))
        model.tick(now: now.addingTimeInterval(31))
        XCTAssertEqual(model.timer(short)?.finished, true)
        XCTAssertEqual(model.timer(muted)?.finished, true)
        XCTAssertEqual(model.timer(long)?.pausedSeconds, 590, "Pausing one timer leaves others alone")
        XCTAssertEqual(rings, 1, "Simultaneous finishes ring once")
        XCTAssertTrue(model.ringing)
        model.tick(now: now.addingTimeInterval(40))
        XCTAssertEqual(rings, 1)
        let before = clears
        model.stop(muted)
        XCTAssertTrue(model.ringing, "A silent timer's dismissal keeps the audible alarm")
        model.stop(short)
        XCTAssertFalse(model.ringing)
        XCTAssertGreaterThan(clears, before)
        model.resume(long, now: now.addingTimeInterval(100))
        XCTAssertEqual(model.timer(long)?.deadline, now.addingTimeInterval(690))
        model.stop()
        XCTAssertTrue(model.timers.isEmpty)
    }

    @MainActor func testWidgetStacksOnePillPerTimerWithOverflow() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let model = QuickToolsModel()
        model.onFinish = {}
        let controller = QuickActivityWidgetController(timer: model, reminders: store)
        defer { model.stop() }
        for seconds in [300.0, 60, 900, 120, 30, 45] { model.addTimer(seconds: seconds) }
        XCTAssertEqual(controller.stackedTimers.map(\.duration), [30, 45, 60, 120], "Soonest first, capped")
        XCTAssertEqual(controller.hiddenTimerCount, 2)
        XCTAssertEqual(controller.size, NSSize(width: 178, height: 4 * 44 + 3 * 8))
        XCTAssertEqual(QuickTimer(id: "a", duration: 600).label, "10 min")
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { return }
        model.stop()
        let now = Date()
        model.addTimer(seconds: 1, now: now.addingTimeInterval(-5))
        model.addTimer(seconds: 600); model.addTimer(seconds: 300)
        model.tick()
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let host = NSHostingView(rootView: QuickActivityWidget(controller: controller).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: controller.size)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/myman-simple-review/widget-stack-dark.png"))
        }
        XCTAssertEqual(QuickTimer(id: "b", duration: 90).label, "1 min 30 sec")
    }
}
