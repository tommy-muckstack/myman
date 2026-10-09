import XCTest
import GRDB
@testable import MyMan

final class BrainNoteSchemaTests: XCTestCase {
    func testMigrationFromV19IsIdempotentAndInstallsTriggers() throws {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue, upTo: "v19-meeting-slide-timestamps")
        let date = Date()
        try queue.write { try $0.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES('n','Old note','kept',?,?)", arguments: [date, date]) }
        try Database.migrator.migrate(queue)
        try Database.migrator.migrate(queue)
        XCTAssertTrue(CaptureSchema.sources.contains { $0.table == "brainNote" })
        try queue.write { db in
            try db.execute(sql: "INSERT INTO brainNote(id,path,title,body,createdAt,updatedAt,mtime,size) VALUES('b','/tmp/x.md','Brainz title','pricing text',?,?,1,10)", arguments: [date, date])
        }
        let item = try XCTUnwrap(try queue.read { try CaptureItem.fetchOne($0, key: "brain-b") })
        XCTAssertEqual(item.kind, "brainNote")
        XCTAssertEqual(item.sourcePath, "/tmp/x.md")
        XCTAssertEqual(item.rawTitle, "Brainz title")
        XCTAssertEqual(item.title, "Brainz title")
        XCTAssertEqual(try CaptureIndex.lexical("pricing", database: queue).map(\.id), ["brain-b"])
        try queue.write { try $0.execute(sql: "UPDATE brainNote SET body = 'revised' WHERE id = 'b'") }
        let revised = try XCTUnwrap(try queue.read { try CaptureItem.fetchOne($0, key: "brain-b") })
        XCTAssertEqual(revised.body, "revised")
        XCTAssertEqual(revised.revision, item.revision + 1)
        try queue.write { try $0.execute(sql: "DELETE FROM brainNote WHERE id = 'b'") }
        XCTAssertNil(try queue.read { try CaptureItem.fetchOne($0, key: "brain-b") })
        XCTAssertNotNil(try queue.read { try CaptureItem.fetchOne($0, key: "note-n") })
    }

    func testFreshDatabaseInstallsEverySource() throws {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        let triggers = try queue.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'capture_%_insert'") }
        for source in CaptureSchema.sources {
            XCTAssertTrue(triggers.contains("capture_\(source.table)_insert"), "missing trigger for \(source.table)")
        }
        XCTAssertEqual(triggers.filter { $0 == "capture_brainNote_insert" }.count, 1)
    }

    @MainActor func testSearchHitAndOpenPathsKnowBrainzNotes() throws {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        let date = Date()
        try queue.write { try $0.execute(sql: "INSERT INTO brainNote(id,path,title,body,createdAt,updatedAt,mtime,size) VALUES('b','/tmp/y.md','T','B',?,?,1,1)", arguments: [date, date]) }
        let item = try XCTUnwrap(try queue.read { try CaptureItem.fetchOne($0, key: "brain-b") })
        let hit = try XCTUnwrap(try queue.read { try item.hit(in: $0) })
        XCTAssertEqual(hit.id, "brain-b")
        XCTAssertEqual(hit.kindLabel, "brainz note")
        XCTAssertEqual(CaptureActions.fileURL(for: item)?.path, "/tmp/y.md")
        XCTAssertEqual(item.kindLabel, "Brainz note")
        XCTAssertEqual(item.bodyMatchLabel, "Matched Brainz note")
    }
}
