import XCTest
@testable import MyMan

final class RecordingEditingToolsTests: XCTestCase {
    func testFreeFormRecipeObjectsPassTheSchemaAndStillMustBeObjects() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["id": ["type": "string"], "recipe": ["type": "object", "description": "free-form"]], "required": ["id"]]
        XCTAssertNoThrow(try AgentSchema.validate(["id": "x", "recipe": ["title": ["text": "Hi", "seconds": 2], "music": ["track": "upbeat"]]], schema: schema))
        XCTAssertThrowsError(try AgentSchema.validate(["id": "x", "recipe": "not an object"], schema: schema))
        XCTAssertThrowsError(try AgentSchema.validate(["id": "x", "unknown": 1], schema: schema), "declared objects stay strict")
    }

    func testTrimmedCopyKeepsCursorClicksAndKeysRetimed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("take.mov"), clip = dir.appendingPathComponent("clip.mp4")
        RecordingSidecars.save(cursor: CursorTrack(separate: true, samples: [.init(t: 1, x: 0.1, y: 0.1), .init(t: 6.5, x: 0.5, y: 0.5), .init(t: 12, x: 0.9, y: 0.9)]), for: source)
        ClickLog.save([.init(time: 2, x: 0.2, y: 0.2), .init(time: 8, x: 0.4, y: 0.6)], for: source)
        RecordingSidecars.save(keys: [.init(t: 7, label: "⌘S"), .init(t: 11, label: "⌘Q")], for: source)

        RecordingSidecars.copyTrimmed(from: source, to: clip, start: 6, end: 10)

        let track = try XCTUnwrap(RecordingSidecars.loadCursor(for: clip))
        XCTAssertTrue(track.separate)
        XCTAssertEqual(track.samples, [.init(t: 0.5, x: 0.5, y: 0.5)])
        XCTAssertEqual(ClickLog.load(for: clip), [.init(time: 2, x: 0.4, y: 0.6)])
        XCTAssertEqual(RecordingSidecars.loadKeys(for: clip), [.init(t: 1, label: "⌘S")])
    }
}
