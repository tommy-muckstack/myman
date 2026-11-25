import XCTest
@testable import MyMan

final class AgentDeliveryTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("man-deliver-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func file(_ name: String, bytes: Int) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url.path
    }

    func testLabelsAcceptSectionIdsOnly() {
        XCTAssertTrue(AgentDelivery.isValidLabel("section-2.intro"))
        XCTAssertFalse(AgentDelivery.isValidLabel("has space"))
        XCTAssertFalse(AgentDelivery.isValidLabel("../escape"))
        XCTAssertFalse(AgentDelivery.isValidLabel(""))
    }

    func testDeliverCopiesFilesAndWritesResultJSON() throws {
        let log = root.appendingPathComponent("changes.jsonl")
        let video = try file("take.mp4", bytes: 1_000)
        let poster = try file("take.png", bytes: 500)
        try AgentChangeLog.append(kind: "clip", id: "c1", paths: ["video": video, "poster": poster], at: "t", url: log)
        let brain = root.appendingPathComponent("brain/agent", isDirectory: true)
        let reply = try AgentDelivery.deliver(id: "c1", to: "claude", brain: brain, log: log)
        XCTAssertEqual(reply["ready_for"] as? String, "claude")
        let folder = brain.appendingPathComponent("artifacts/c1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.json").path))
        let entries = try AgentChangeLog.load(log)
        XCTAssertEqual(entries.last?.kind, "delivery")
        XCTAssertEqual(entries.last?.readyFor, "claude")
    }

    func testAFileOverTheToolLimitRefusesTheWholeDeliveryAndCopiesNothing() throws {
        let log = root.appendingPathComponent("changes.jsonl")
        let small = try file("small.png", bytes: 100)
        let big = try file("big.mp4", bytes: AgentDelivery.toolUploadLimit + 1)
        try AgentChangeLog.append(kind: "narration", id: "n1", paths: ["a": small, "video": big], at: "t", url: log)
        let brain = root.appendingPathComponent("brain/agent", isDirectory: true)
        XCTAssertThrowsError(try AgentDelivery.deliver(id: "n1", to: "claude", brain: brain, log: log))
        XCTAssertFalse(FileManager.default.fileExists(atPath: brain.appendingPathComponent("artifacts/n1/small.png").path))
    }

    func testUnknownIdsAndTargetsAreRefused() throws {
        let log = root.appendingPathComponent("changes.jsonl")
        XCTAssertThrowsError(try AgentDelivery.deliver(id: "nope", to: "claude", brain: root, log: log))
        XCTAssertThrowsError(try AgentDelivery.deliver(id: "nope", to: "email", brain: root, log: log))
    }
}
