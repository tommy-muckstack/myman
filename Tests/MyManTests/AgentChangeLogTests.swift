import XCTest
@testable import MyMan

final class AgentChangeLogTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("man-changes-\(UUID().uuidString)").appendingPathComponent("agent-changes.jsonl")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func testChangesSinceReturnsOnlyNewerEntriesAndTheNextCursor() throws {
        for id in ["a", "b", "c"] { try AgentChangeLog.append(kind: "screenshot", id: id, at: "2026-11-24T10:00:00.000Z", url: url) }
        let first = try AgentChangeLog.since(cursor: 0, url: url)
        XCTAssertEqual(first.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(first.cursor, 3)
        try AgentChangeLog.append(kind: "screenshot", id: "d", readyFor: "paper-doc", at: "2026-11-24T10:01:00.000Z", url: url)
        let next = try AgentChangeLog.since(cursor: first.cursor, url: url)
        XCTAssertEqual(next.items.map(\.id), ["d"])
        XCTAssertEqual(next.items.first?.readyFor, "paper-doc")
        XCTAssertEqual(try AgentChangeLog.since(cursor: next.cursor, url: url).items, [])
    }

    func testLimitIsCappedAndPagesFromTheCursor() throws {
        for index in 0 ..< 5 { try AgentChangeLog.append(kind: "screenshot", id: "\(index)", at: "t", url: url) }
        let page = try AgentChangeLog.since(cursor: 0, limit: 2, url: url)
        XCTAssertEqual(page.items.map(\.id), ["0", "1"])
        XCTAssertEqual(try AgentChangeLog.since(cursor: page.cursor, limit: 2, url: url).items.map(\.id), ["2", "3"])
        XCTAssertEqual(try AgentChangeLog.since(cursor: 0, limit: 10_000, url: url).items.count, 5)
    }

    func testTheLogKeepsItsLastEntriesButNeverReusesSequenceNumbers() throws {
        for index in 0 ... AgentChangeLog.maximumEntries { try AgentChangeLog.append(kind: "screenshot", id: "\(index)", at: "t", url: url) }
        let entries = try AgentChangeLog.load(url)
        XCTAssertEqual(entries.count, AgentChangeLog.maximumEntries)
        XCTAssertEqual(entries.last?.seq, AgentChangeLog.maximumEntries + 1)
    }

    func testAnUnreadableLineIsSkippedNotFatal() throws {
        try AgentChangeLog.append(kind: "screenshot", id: "good", at: "t", url: url)
        try (try String(contentsOf: url, encoding: .utf8) + "not json\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try AgentChangeLog.since(cursor: 0, url: url).items.map(\.id), ["good"])
    }

    func testEntriesNeverCarryContentFields() throws {
        let entry = try AgentChangeLog.append(kind: "screenshot", id: "x", paths: ["image": "/a.png"], at: "t", url: url)
        XCTAssertEqual(Set(entry.json.keys), ["cursor", "at", "kind", "id", "paths", "ready_for"])
    }
}
