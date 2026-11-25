import XCTest
@testable import MyMan

final class ClaudeDesktopConnectorTests: XCTestCase {
    private var folder: URL!
    private var original: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        original = ClaudeDesktopConnector.configURL
        ClaudeDesktopConnector.configURL = folder.appendingPathComponent("claude_desktop_config.json")
    }

    override func tearDownWithError() throws {
        ClaudeDesktopConnector.configURL = original
        try? FileManager.default.removeItem(at: folder)
    }

    private func readJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: ClaudeDesktopConnector.configURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Other servers and settings survive connecting and disconnecting.
    func testWriteAndRemoveKeepOtherEntries() throws {
        let existing: [String: Any] = ["theme": "dark", "mcpServers": ["other": ["command": "x", "args": []]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: ClaudeDesktopConnector.configURL)

        try ClaudeDesktopConnector.writeServer(command: "/usr/local/bin/node", script: "/Applications/MyMan.app/walkthrough-mcp.mjs")
        var config = try readJSON()
        XCTAssertEqual(config["theme"] as? String, "dark")
        var servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let mine = try XCTUnwrap(servers["myman"] as? [String: Any])
        XCTAssertEqual(mine["command"] as? String, "/usr/local/bin/node")
        XCTAssertEqual(mine["args"] as? [String], ["/Applications/MyMan.app/walkthrough-mcp.mjs"])

        try ClaudeDesktopConnector.removeServer()
        config = try readJSON()
        servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["myman"])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual(config["theme"] as? String, "dark")
    }

    /// A config that cannot be parsed is never overwritten.
    func testUnreadableConfigIsLeftAlone() throws {
        let garbage = Data("{not json".utf8)
        try garbage.write(to: ClaudeDesktopConnector.configURL)
        XCTAssertThrowsError(try ClaudeDesktopConnector.writeServer(command: "/node", script: "/s.mjs"))
        XCTAssertEqual(try Data(contentsOf: ClaudeDesktopConnector.configURL), garbage)
    }

    /// No file means an empty config, and connecting creates it.
    func testMissingConfigIsCreated() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeDesktopConnector.configURL.path))
        try ClaudeDesktopConnector.writeServer(command: "/node", script: "/s.mjs")
        XCTAssertNotNil(try readJSON()["mcpServers"])
    }
}
