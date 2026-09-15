import XCTest
import GRDB
@testable import MyMan

final class BrainAgentExportTests: XCTestCase {
    private func fixture() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        try queue.write { db in
            let date = Date(timeIntervalSince1970: 1_788_523_200)
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,endedAt,transcript,summary) VALUES(?,?,?,?,?,?)", arguments: ["call", "Design review", date, date.addingTimeInterval(3600), "**Jordan Rivera** [0:00]: Review the registration pricing.\n**Casey Taylor** [0:10]: The plan costs $49.", "Discussed registration pricing."])
            try db.execute(sql: "INSERT INTO screenshot(id,path,ocrText,createdAt) VALUES(?,?,?,?)", arguments: ["image", "/Users/example/Captures/Pricing screen.png", "Registration price $49", date.addingTimeInterval(1800)])
            try db.execute(sql: "INSERT INTO dictation(id,text,createdAt) VALUES(?,?,?)", arguments: ["thought", "Follow up on the pricing experiment", date.addingTimeInterval(2400)])
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('topic','Registration pricing','registration pricing')")
            try db.execute(sql: "UPDATE captureItem SET pinned=1,userTitle='Pricing comparison' WHERE id='shot-image'")
            for id in ["meeting-call", "shot-image", "dictation-thought"] { try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('topic',?)", arguments: [id]) }
            for i in 0..<135 {
                try db.execute(sql: "INSERT INTO task(id,title,source,done,createdAt,notes,completedAt) VALUES(?,?,?,?,?,?,?)", arguments: ["task-\(i)", "Pricing research \(i)", "manual", i >= 35, date, "Compare plans, taxes, and renewal prices.", i >= 35 ? date.addingTimeInterval(7200) : nil])
            }
        }
        return queue
    }

    func testCatalogIncludesCompleteTasksDictationThemesAndOriginalMeetingInterval() throws {
        let db = try fixture()
        let snapshot = try db.read { try BrainAgentExport.snapshot(in: $0) }
        XCTAssertEqual(snapshot.catalog.exports.filter { $0.kind == "tasks" }.count, 135)
        XCTAssertEqual(snapshot.catalog.exports.filter { $0.kind == "tasks" && $0.done == false }.count, 35)
        let shot = try XCTUnwrap(snapshot.catalog.exports.first { $0.kind == "screenshots" })
        XCTAssertEqual(shot.title, "Pricing comparison"); XCTAssertTrue(shot.pinned)
        XCTAssertEqual(shot.themes.map(\.title), ["Registration pricing"])
        let call = try XCTUnwrap(snapshot.catalog.exports.first { $0.kind == "meetings" })
        let markdown = try XCTUnwrap(snapshot.documents[call.path])
        XCTAssertTrue(markdown.contains("  - Jordan Rivera")); XCTAssertTrue(markdown.contains("ended: "))
        XCTAssertTrue(markdown.contains("**Casey Taylor** [0:10]: The plan costs $49."))
        XCTAssertTrue(snapshot.documents["task-items/task-134.md"]?.contains("Compare plans, taxes, and renewal prices.") == true)
        let theme = try XCTUnwrap(snapshot.documents["themes/topic.md"])
        XCTAssertTrue(theme.contains(shot.path)); XCTAssertTrue(theme.contains(call.path))
        XCTAssertEqual(snapshot.catalog.exports.filter { $0.kind == "dictations" }.count, 1)
        // Optional synthetic cross-language fixture for CLI/MCP integration QA.
        if let path = ProcessInfo.processInfo.environment["MAN_BRAIN_EXPORT_FIXTURE_DIR"] {
            let root = URL(fileURLWithPath: path)
            for (relative, content) in snapshot.documents {
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: file, atomically: true, encoding: .utf8)
            }
            try JSONEncoder().encode(snapshot.catalog).write(to: root.appendingPathComponent("catalog.json"))
        }
    }

    func testExclusionDeletionAndThemeCorrectionsRemoveCatalogEvidence() throws {
        let db = try fixture()
        try db.write { db in
            try db.execute(sql: "UPDATE captureItem SET excluded=1 WHERE id='shot-image'")
            try db.execute(sql: "DELETE FROM dictation WHERE id='thought'")
            try db.execute(sql: "DELETE FROM task WHERE id='task-1'")
            try db.execute(sql: "UPDATE captureTheme SET title='Launch pricing' WHERE id='topic'")
        }
        let snapshot = try db.read { try BrainAgentExport.snapshot(in: $0) }
        XCTAssertFalse(snapshot.catalog.exports.contains { ["screenshots", "dictations"].contains($0.kind) })
        XCTAssertNil(snapshot.documents["task-items/task-1.md"])
        XCTAssertEqual(snapshot.catalog.exports.filter { $0.kind == "tasks" }.count, 134)
        XCTAssertTrue(snapshot.documents["themes/topic.md"]?.contains("Launch pricing") == true)
        XCTAssertFalse(snapshot.documents["themes/topic.md"]?.contains("Pricing comparison") == true)
        try db.write { try $0.execute(sql: "UPDATE captureTheme SET dismissed=1 WHERE id='topic'") }
        let dismissed = try db.read { try BrainAgentExport.snapshot(in: $0) }
        XCTAssertNil(dismissed.documents["themes/topic.md"])
        XCTAssertTrue(dismissed.catalog.exports.allSatisfy { $0.themes.isEmpty })
    }
}
