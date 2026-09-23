import AppKit
import SwiftUI
import XCTest
import GRDB
@testable import MyMan

final class AdaptiveLauncherTests: XCTestCase {
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

    @MainActor func testNativeVisualReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ADAPTIVE_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, query) in [("empty", ""), ("ambiguous", "budget"), ("checklist", "buy milk, eggs and coffee"), ("split", "split $100 between 3"), ("timer", "25 min focus"), ("dark", "25 min focus")] {
            let voice = AdaptiveLauncherVoice(dependencies: .init(
                authorize: { true }, prepare: { true }, begin: { UUID() }, end: { _ in [] },
                discard: { _ in }, level: { _ in 0.02 }, transcribe: { _ in "" }
            ), automaticallyPoll: false)
            let view = AdaptiveLauncherView(actions: [], initialQuery: query, voice: voice, onSaveQueryAsNote: { _ in }, onDismiss: {}, onSizeChange: { _ in })
                .frame(width: 620, height: 450).preferredColorScheme(name == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            voice.start()
            try await Task.sleep(for: .milliseconds(200))
            voice.sample()
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
            voice.stop()
        }
    }
}
