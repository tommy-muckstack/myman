import AppKit
import SwiftUI
import XCTest
import GRDB
@testable import MyMan

final class AdaptiveLauncherTests: XCTestCase {
    @MainActor func testSpokenArithmeticRoutesToCalculatorWithoutTreatingProseAsMath() {
        for (text, expected) in [("what's one plus one?", 2.0), ("whats one plus one", 2),
                                 ("What’s twelve divided by four?", 3), ("calculate twenty-one times two", 42),
                                 ("one hundred and twenty three minus three", 120), ("one point five plus two", 3.5),
                                 ("negative five plus two", -3), ("what is two plus three times four", 14),
                                 ("eighteen percent of two hundred", 36)] {
            guard case .calculation(_, let value) = QuickToolParser.parse(text) else { XCTFail(text); continue }
            XCTAssertEqual(value, expected, accuracy: 0.0001, text)
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(text), .create, text)
            XCTAssertEqual(AgentQuickTools.evaluate(text)["value"] as? Double, expected)
        }
        for text in ["one plus one ideas for launch", "plus one guest", "what is my budget", "one two plus three"] {
            guard case .note = QuickToolParser.parse(text) else { XCTFail("Must retain prose: \(text)"); continue }
        }
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find one plus one"), .search)
    }

    @MainActor func testCompletedSpeechReachesCalculatorAfterMicrophoneStops() async throws {
        _ = NSApplication.shared
        var time = 0.0
        var volume: Float = 0.03
        var starts = 0
        let voice = AdaptiveLauncherVoice(dependencies: .init(authorize: { true }, prepare: { true },
            begin: { starts += 1; return UUID() }, end: { _ in Array(repeating: 0.01, count: 16_000) },
            discard: { _ in }, level: { _ in volume }, transcribe: { _ in "What's one plus one?" },
            now: { Date(timeIntervalSince1970: time) }), automaticallyPoll: false)
        let model = QuickToolsModel()
        let host = NSHostingView(rootView: AdaptiveLauncherView(actions: [], voice: voice,
            onSaveQueryAsNote: { _ in XCTFail("A calculation must not save a note") }, onDismiss: {}, onSizeChange: { _ in }, tools: model))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 200)
        host.layoutSubtreeIfNeeded()
        defer { voice.stop() }
        voice.start()
        try await Task.sleep(for: .milliseconds(100))
        for instant in [0.1, 0.2, 0.3] { time = instant; voice.sample() }
        volume = 0
        for instant in [0.4, 1.5] { time = instant; voice.sample() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.tool, .calculation("1 + 1", 2))
        XCTAssertFalse(voice.enabled)
        XCTAssertEqual(voice.phase, .off)
        XCTAssertEqual(starts, 1)
    }

    func testManualChoiceSurvivesTypingUntilTheRequestIsCleared() {
        var routing = AdaptiveLauncherRouting()
        routing.update("budget")
        routing.selection = .search
        routing.update("split $120 between 3")
        XCTAssertEqual(routing.selection, .search)
        routing.suggestion = .create
        XCTAssertEqual(routing.selection, .search, "A delayed suggestion cannot replace a manual choice")
        routing.update("")
        XCTAssertNil(routing.selection)
        XCTAssertEqual(routing.suggestion, .choose)
        routing.selection = .create
        routing.update("find my notes")
        XCTAssertEqual(routing.selection, .create)
        routing.update("/")
        XCTAssertNil(routing.selection)
        XCTAssertEqual(routing.suggestion, .commands)
    }

    func testSearchWinsOverEmbeddedCreationWords() {
        for input in ["find my checklist", "search for split $120 between 3", "show me screenshot notes", "where did I record a meeting", "look for timer 25 min"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .search, input)
        }
        let search = CaptureQuery.resolve(AdaptiveLauncherIntent.searchText("search for launch notes"), filter: CaptureFilter())
        XCTAssertEqual(search.text, "launch")
        XCTAssertEqual(search.filter.kind, "note")
        XCTAssertEqual(AdaptiveLauncherIntent.searchText("find \"launch notes\""), "\"launch notes\"")
        XCTAssertEqual(AdaptiveLauncherIntent.searchText("find "), "")
    }

    func testAmbiguousTopicsRequireAChoice() {
        for input in ["budget", "project launch", "meeting with Sam", "the screenshot problem", "", "record", "2026"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .choose, input)
        }
    }

    func testExplicitCreateAndCaptureRoutes() {
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("make a checklist milk, eggs"), .create)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("take a screenshot"), .action("screenshot"))
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("record my screen"), .action("record"))
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("my calendar"), .calendar)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("my tasks"), .tasks)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("/"), .commands)
        XCTAssertEqual(AdaptiveLauncherIntent.creationText("create a note: Launch plan"), "Launch plan")
        XCTAssertFalse(QuickToolParser.parse(AdaptiveLauncherIntent.creationText("new note")).canSave)
        XCTAssertEqual(QuickToolParser.parse(AdaptiveLauncherIntent.creationText("make a checklist milk, eggs")), .checklist(["milk", "eggs"]))
    }

    func testMathPrecedencePercentagesAndInvalidInput() {
        XCTAssertEqual(QuickToolParser.parse("calculator"), .calculator)
        XCTAssertEqual(QuickToolParser.parse("calc"), .calculator)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("calculator"), .create)
        XCTAssertEqual(QuickToolParser.parse("calculator 18% of 240"), .calculation("18% of 240", 43.2))
        XCTAssertEqual(QuickToolParser.parse("2 + 3 * (4 - 1)"), .calculation("2 + 3 * (4 - 1)", 11))
        XCTAssertEqual(QuickToolParser.parse("-3 * -2"), .calculation("-3 * -2", 6))
        XCTAssertEqual(QuickToolParser.parse("12 ÷ 3 − 1"), .calculation("12 ÷ 3 - 1", 3))
        XCTAssertEqual(QuickToolParser.parse("18% of 240"), .calculation("18% of 240", 43.2))
        XCTAssertEqual(QuickToolParser.parse("25% off 100"), .calculation("25% off 100", 75))
        for input in ["1 / 0", "2 +", "(2 * 3", "1.2.3 + 4", String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40)] {
            XCTAssertFalse(QuickToolParser.parse(input).canSave, input)
        }
        XCTAssertEqual(QuickToolParser.parse("launch plan"), .note("launch plan"))
        XCTAssertFalse(QuickToolParser.parse(String(repeating: "a", count: 2_001)).canSave)
    }

    func testConversionsAreCompatibleAndUseTemperatureOffsets() {
        guard case .conversion(_, let miles, _) = QuickToolParser.parse("5 miles in km"),
              case .conversion(_, let celsius, _) = QuickToolParser.parse("32f to c"),
              case .conversion(_, let fahrenheit, _) = QuickToolParser.parse("100 c to f") else {
            return XCTFail("Expected conversions")
        }
        XCTAssertEqual(miles, 8.04672, accuracy: 0.000001)
        XCTAssertEqual(celsius, 0, accuracy: 0.000001)
        XCTAssertEqual(fahrenheit, 212, accuracy: 0.000001)
        XCTAssertFalse(QuickToolParser.parse("5 miles in kg").canSave)
    }

    func testSplitAccountsForEveryCentAndRejectsInvalidCounts() {
        XCTAssertEqual(QuickToolParser.parse("split $100 between 3"), .split(cents: 10_000, people: 3, currency: "$"))
        XCTAssertEqual(QuickTool.splitSummary(cents: 10_000, people: 3, currency: "$"), "2 × $33.33\n1 × $33.34")
        XCTAssertEqual(QuickTool.splitSummary(cents: 12_000, people: 3, currency: ""), "40.00 each")
        for input in ["split $10 between 0", "split $10 between 1001", "split $10.001 between 3", "split -2 between 3"] {
            XCTAssertFalse(QuickToolParser.parse(input).canSave, input)
        }
    }

    func testTimerAndColorParsing() {
        XCTAssertEqual(QuickToolParser.parse("25 min focus"), .timer(1_500))
        XCTAssertEqual(QuickToolParser.parse("timer 1 hour 30 minutes"), .timer(5_400))
        XCTAssertEqual(QuickToolParser.parse("set a timer for 30 seconds"), .timer(30))
        XCTAssertFalse(QuickToolParser.parse("timer 25 hours").canSave)
        XCTAssertFalse(QuickToolParser.parse("timer 0 seconds").canSave)
        XCTAssertEqual(QuickToolParser.parse("#abc"), .color("#AABBCC"))
        XCTAssertFalse(QuickToolParser.parse("#ab").canSave)
    }

    @MainActor func testChecklistEditsRetainOnlyMatchingCheckedItems() {
        let model = QuickToolsModel()
        model.update("buy milk, eggs and coffee")
        model.checked = [0, 1]
        model.update("buy milk, bread and coffee")
        XCTAssertEqual(model.checked, [0])
        XCTAssertEqual(model.tool.markdown(checked: model.checked), "Checklist\n\n- [x] milk\n- [ ] bread\n- [ ] coffee")
        model.update("25 min focus")
        XCTAssertTrue(model.checked.isEmpty)
        XCTAssertNil(model.deadline, "Parsing a timer must not start one")
    }

    @MainActor func testTimerPauseResumeAndChangingCardDoNotLoseDeadline() {
        let model = QuickToolsModel()
        var alarms = 0
        model.onFinish = { alarms += 1 }
        let now = Date(timeIntervalSince1970: 100)
        model.start(seconds: 30, now: now)
        model.update("buy milk")
        XCTAssertEqual(model.deadline, now.addingTimeInterval(30))
        model.pause(now: now.addingTimeInterval(10))
        XCTAssertEqual(model.pausedSeconds, 20)
        model.start(seconds: model.pausedSeconds!, now: now.addingTimeInterval(40))
        model.tick(now: now.addingTimeInterval(61))
        model.tick(now: now.addingTimeInterval(62))
        XCTAssertTrue(model.finished)
        XCTAssertEqual(alarms, 1)
        model.stop()
        XCTAssertFalse(model.finished)
        XCTAssertNil(model.deadline)
    }

    @MainActor func testAdaptiveSearchLoadsExistingCapturesWithoutCreatingANote() async throws {
        _ = NSApplication.shared
        let database = try DatabaseQueue()
        try Database.migrator.migrate(database)
        try await database.write { db in
            let date = Date()
            try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)",
                           arguments: ["fixture", "Launch checklist", "Verify packaging", date, date])
        }
        let model = CaptureLibraryModel(database: database)
        var saves = 0
        let host = NSHostingView(rootView: AdaptiveLauncherView(
            actions: [], initialQuery: "find my checklist", libraryModel: model,
            onSaveQueryAsNote: { _ in saves += 1 }, onDismiss: {}, onSizeChange: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 600)
        host.layoutSubtreeIfNeeded()
        defer { model.cancel() }
        for _ in 0..<100 where model.results.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.results.map(\.id), ["note-fixture"])
        XCTAssertEqual(saves, 0)
        let count = try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") }
        XCTAssertEqual(count, 1)
        withExtendedLifetime(host) {}
    }

    @MainActor func testTypingStopsListeningThroughTheActualInput() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { throw XCTSkip("Opt-in native input verification") }
        _ = NSApplication.shared
        var ended = 0
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let voice = AdaptiveLauncherVoice(dependencies: .init(
            authorize: { true }, prepare: { true }, begin: { UUID() }, end: { _ in ended += 1; return [] },
            discard: { _ in }, level: { _ in 0 }, transcribe: { _ in "" }
        ), automaticallyPoll: false, preferences: preferences)
        let panel = FloatingPanel(content: AdaptiveLauncherView(actions: [], voice: voice,
            onSaveQueryAsNote: { _ in }, onDismiss: {}, onSizeChange: { _ in }, tools: QuickToolsModel()), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.dismissesOnResign = false
        panel.setContentSize(NSSize(width: 620, height: 200))
        defer { voice.stop(); panel.contentView = nil; panel.close() }
        panel.makeKeyAndOrderFront(nil)
        voice.start()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(voice.phase, .listening)
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try XCTUnwrap(textField(in: try XCTUnwrap(panel.contentView)))
        panel.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("timer for 20m", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(voice.phase, .off)
        XCTAssertFalse(voice.enabled)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(field.stringValue, "timer for 20m")
        editor.insertText("/", replacementRange: NSRange(location: 0, length: field.stringValue.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "", "Slash opens the picker without becoming query text")
        editor.insertText("record", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "record")
        editor.insertText("", replacementRange: NSRange(location: 0, length: field.stringValue.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.phase, .listening, "Clearing a request restarts listening")
        voice.mute()
        editor.insertText("calculator", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("", replacementRange: NSRange(location: 0, length: field.stringValue.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.phase, .off, "Clearing must respect a persistent mute")
        preferences.removeObject(forKey: AdaptiveListeningPreference.key)
    }

    @MainActor func testRecordCommandButton() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] != nil else { throw XCTSkip("Opt-in native command verification") }
        _ = NSApplication.shared
        var calls = 0
        var size = CGSize(width: 620, height: 90)
        let action = LauncherAction(id: "meeting", icon: .calendar, title: "Record Meeting", hint: nil, enabled: true) { calls += 1 }
        let panel = FloatingPanel(content: AdaptiveLauncherView(actions: [action], initialQuery: "record meeting",
            onSaveQueryAsNote: { _ in }, onDismiss: {}, onSizeChange: { size = $0 }, tools: QuickToolsModel()), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.dismissesOnResign = false
        panel.setContentSize(size)
        defer { panel.contentView = nil; panel.close() }
        panel.present()
        try await Task.sleep(for: .milliseconds(200))
        panel.setContentSize(size)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 0)
        let host = try XCTUnwrap(panel.contentView)
        var expected = 0
        // Pixel-aligned points spanning the visible capsule, using a simulated
        // command so this verification never records audio or screen content.
        for x in [480.0, 500, 520] {
            for y in [18.0, 30, 42] {
                let point = NSPoint(x: x, y: y)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0))
                    NSApp.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(100))
                expected += 1
                XCTAssertEqual(calls, expected, "One action per click at \(point)")
            }
        }
    }

    @MainActor func testNativeVisualReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let fixtures = [("empty", ""), ("themes", ""), ("ambiguous", "budget"), ("checklist", "buy milk, eggs and coffee"),
                        ("split", "split $100 between 3"), ("timer", "timer for 20m"), ("running", "timer for 20m"),
                        ("paused", "timer for 20m"), ("color", "#fffffd"), ("orange", "#ff6b35"),
                        ("timezone", "8am in Iceland"), ("calculation", "18% of 240"), ("record", "record meeting"),
                        ("timezone-reversed", "8am Los Angeles to New York"),
                        ("timezone-fixed", "8am EST to PST"),
                        ("commands", "/record"), ("calculator-open", "calculator"), ("quick-tools", "quick tools"),
                        ("reminder", "reminder in 10m for taking pizza out"),
                        ("long", "checklist " + (1...30).map { "Task \($0)" }.joined(separator: ", "))]
        for scheme in [ColorScheme.dark, .light] {
            for (name, query) in fixtures {
                let voice = AdaptiveLauncherVoice(dependencies: .init(
                    authorize: { true }, prepare: { true }, begin: { UUID() }, end: { _ in [] },
                    discard: { _ in }, level: { _ in 0.02 }, transcribe: { _ in "" }
                ), automaticallyPoll: false)
                let tools = QuickToolsModel()
                tools.update(query)
                if name == "running" || name == "paused" { tools.start(seconds: 1_200) }
                if name == "paused" { tools.pause() }
                var measured = CGSize(width: 620, height: 400)
                var actionCalls = 0
                let definitions: [(String, MMIcon, String, String)] = [
                    ("screenshot", .screenshot, "Take Screenshot", "⌥S"), ("note", .note, "New Note", "⌥N"),
                    ("voice", .voice, "Voice Dictation", "⌥V"), ("meeting", .calendar, "Record Meeting", "⌥M"),
                    ("record", .recordScreen, "Record Screen", "⌥R"), ("quick_tools", .agent, "Quick Tools", "")]
                let actions = definitions.map { id, icon, title, hint in
                    LauncherAction(id: id, icon: icon, title: title, hint: hint, enabled: true) { actionCalls += 1 }
                }
                let database = try DatabaseQueue()
                try Database.migrator.migrate(database)
                if name == "themes" {
                    try await database.write { db in
                        try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES('theme-fixture','Launch checklist','Review the next release',?,?)", arguments: [Date(), Date()])
                        try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('release','Release planning','release')")
                        try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('release','note-theme-fixture')")
                    }
                }
                let library = CaptureLibraryModel(database: database)
                defer { library.cancel() }
                let panel = FloatingPanel(content: AdaptiveLauncherView(actions: actions, initialQuery: query, libraryModel: library, voice: voice,
                    onSaveQueryAsNote: { _ in }, onDismiss: {}, onSizeChange: { measured = $0 }, tools: tools)
                    .preferredColorScheme(scheme), fixedSize: true)
                panel.isReleasedWhenClosed = false
                panel.isMovable = false
                panel.setContentSize(measured)
                let host = try XCTUnwrap(panel.contentView)
                defer { voice.stop(); tools.stop(); panel.contentView = nil; panel.close() }
                host.layoutSubtreeIfNeeded()
                if query.isEmpty { voice.start() }
                try await Task.sleep(for: .milliseconds(200))
                if query.isEmpty { voice.sample() }
                panel.setContentSize(measured)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                panel.setContentSize(measured)
                if name == "themes" {
                    panel.dismissesOnResign = false
                    panel.makeKeyAndOrderFront(nil)
                    let point = NSPoint(x: 556, y: host.isFlipped ? 28 : host.bounds.height - 28)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                    }
                    for _ in 0..<100 where library.themes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                    XCTAssertEqual(library.themes.map(\.title), ["Release planning"])
                    XCTAssertFalse(voice.enabled, "Opening Themes stops voice capture")
                    panel.setContentSize(measured)
                    host.layoutSubtreeIfNeeded()
                }
                if ["timer", "running", "paused"].contains(name) { XCTAssertLessThan(measured.height, 180) }
                if name == "color" { XCTAssertLessThan(measured.height, 280) }
                if name == "record" { XCTAssertLessThan(measured.height, 70) }
                if name == "long" { XCTAssertLessThan(measured.height, 410); XCTAssertGreaterThan(measured.height, 300) }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                XCTAssertEqual(actionCalls, 0, "Rendering a command must not execute it")
            }
        }
    }
}
