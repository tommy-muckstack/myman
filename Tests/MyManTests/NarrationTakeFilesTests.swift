import XCTest
@testable import MyMan

final class NarrationTakeFilesTests: XCTestCase {
    private var folder: URL!
    private var movie: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("narrations-\(UUID().uuidString)", isDirectory: true)
        movie = folder.deletingLastPathComponent().appendingPathComponent("take-\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: movie)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: movie)
    }

    private func meta(_ id: String) -> [String: Any] {
        ["id": id, "label": "test", "request": NSNull(), "startedAtEpochMs": 1_700_000_000_000 as Int64,
         "durationMs": 30_000, "bytes": 5, "mimeType": "video/mp4", "width": 480, "height": 480,
         "stoppedBy": "url", "stopReason": "Stopped by myman://narration/stop."]
    }

    /// A take is written as its video, its metadata, and latest.json.
    func testPublishWritesVideoMetadataAndLatest() throws {
        try NarrationTakeFiles.publish(movie: movie, metadata: meta("take-a"), in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take-a.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take-a.json").path))
        let latest = try Data(contentsOf: folder.appendingPathComponent("latest.json"))
        let parsed = try JSONSerialization.jsonObject(with: latest) as? [String: Any]
        XCTAssertEqual(parsed?["id"] as? String, "take-a")
        XCTAssertEqual(parsed?["stoppedBy"] as? String, "url")
    }

    /// Only the newest 20 takes are kept; older videos and their metadata are removed.
    func testKeepsTheNewestTwentyTakes() throws {
        for index in 0 ..< 23 {
            try NarrationTakeFiles.publish(movie: movie, metadata: meta("take-\(index)"), in: folder)
            // Space the videos' write times so their order is clear.
            let when = Date(timeIntervalSinceNow: Double(index) - 100)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: folder.appendingPathComponent("take-\(index).mp4").path)
        }
        NarrationTakeFiles.prune(in: folder)
        let videos = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mp4") }
        XCTAssertEqual(videos.count, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take-0.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take-0.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take-22.mp4").path))
    }
}
