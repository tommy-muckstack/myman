import XCTest
@testable import MyMan

final class AgentBridgeStatusTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("man-status-\(UUID().uuidString)", isDirectory: true)
        for folder in ["inbox", "outbox"] { try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testOffWhenAgentsAreOff() {
        XCTAssertEqual(AgentBridgeStatus.read(root: root, agentsOn: false).line, "Brain folder: off")
    }
    func testNeedsAttentionWithoutAFreshHeartbeat() {
        XCTAssertEqual(AgentBridgeStatus.read(root: root, agentsOn: true).connection, .needsAttention)
    }
    func testConnectedCountsWaitingApprovals() throws {
        try Data("{}".utf8).write(to: root.appendingPathComponent("heartbeat.json"))
        try Data(#"{"ok":false,"pending":true}"#.utf8).write(to: root.appendingPathComponent("outbox/a.json"))
        try Data(#"{"ok":true}"#.utf8).write(to: root.appendingPathComponent("outbox/b.json"))
        let status = AgentBridgeStatus.read(root: root, agentsOn: true)
        XCTAssertEqual(status.connection, .connected)
        XCTAssertEqual(status.waitingForPerson, 1)
        XCTAssertTrue(status.line.contains("1 waiting for you"))
        XCTAssertNotNil(status.lastRequest)
    }
    func testAgeWordsAreShort() {
        let now = Date()
        XCTAssertEqual(AgentBridgeStatus.ago(now, now: now), "just now")
        XCTAssertEqual(AgentBridgeStatus.ago(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(AgentBridgeStatus.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
    }
}
