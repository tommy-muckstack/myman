import XCTest
import AppKit
import GRDB
@testable import MyMan

final class AgentWorkflowTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myman-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testReceiptsRecoverArtifactsAndInterruptWithoutReplaying() throws {
        let root = try root(), id = UUID().uuidString, pending = UUID().uuidString, fingerprint = Data("request-one".utf8)
        let journal = AgentJournal(root: root)
        try journal.begin(id, action: "note.create", fingerprint: fingerprint)
        XCTAssertTrue(journal.finish(id, job: ["id":id,"action":"note.create","state":"succeeded","result":["id":"note-saved","path":"/saved/font.otf","attachment":["preview_path":"/cache/AgentMedia/old.png"]]]))
        try journal.begin(pending, action: "font.create", fingerprint: Data("request-two".utf8))
        XCTAssertTrue(journal.saveSession("session", result: ["session_id":"session","state":"finalized","id":"recording-saved"]))
        let recovered = AgentJournal(root: root)
        let result = try XCTUnwrap(try recovered.prior(id, fingerprint: fingerprint)?["result"] as? [String: Any])
        XCTAssertEqual(result["id"] as? String, "note-saved")
        XCTAssertTrue((result["attachment"] as? [String: Any])?["preview_path"] is NSNull)
        XCTAssertEqual(recovered.job(pending)?["state"] as? String, "interrupted")
        XCTAssertEqual(recovered.session("session")?["id"] as? String, "recording-saved")
        XCTAssertThrowsError(try recovered.prior(id, fingerprint: Data("different".utf8)))
        XCTAssertEqual(recovered.list().count, 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("receipts.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    @MainActor func testDeletingContentRedactsDurableResultsAndKeepsDeduplication() throws {
        let root = try root(), id = UUID().uuidString, fingerprint = Data("request".utf8)
        let journal = AgentJournal(root: root)
        try journal.begin(id, action: "note.create", fingerprint: fingerprint)
        XCTAssertTrue(journal.finish(id, job: ["id":id,"action":"note.create","state":"succeeded","result":["body":"sensitive fixture"]]))
        _ = journal.saveSession("session", result: ["path":"/sensitive-fixture.mov"])
        journal.purgeContent()
        let restored = AgentJournal(root: root)
        XCTAssertEqual(try restored.prior(id, fingerprint: fingerprint)?["state"] as? String, "failed")
        XCTAssertNil(restored.session("session"))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("receipts.json"), encoding: .utf8).contains("sensitive"))
    }
    @MainActor func testUnreadableJournalFailsBeforeStartingAndLargeResultsStayBounded() throws {
        let root = try root()
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("receipts.json"))
        let failed = AgentJournal(root: root)
        XCTAssertThrowsError(try failed.begin(UUID().uuidString, action: "note.create", fingerprint: Data()))
        let other = try self.root(), journal = AgentJournal(root: other), id = UUID().uuidString
        try journal.begin(id, action: "screenshot.image", fingerprint: Data())
        XCTAssertTrue(journal.finish(id, job: ["id":id,"state":"succeeded","result":["id":"shot-one","data":String(repeating:"x",count:100000)]]))
        XCTAssertEqual((AgentJournal(root: other).job(id)?["result"] as? [String: Any])?["recovery_status"] as? String, "large_result_omitted")
    }
    func testNativeSearchUsesRankingTyposFiltersAndExplicitSemanticOptOut() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        try db.write { db in
            for (id,title,body) in [("title","Registration pricing","First"),("body","Other","Registration pricing discussion"),("hidden","Registration pricing secret","Hidden")] {
                try db.execute(sql:"INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)",arguments:[id,title,body,Date(),Date()])
            }
            try db.execute(sql:"UPDATE captureItem SET excluded=1 WHERE id='note-hidden'")
        }
        let exact = try AgentSearch.run(["query":"Registration pricing","limit":1.0], database: db, semanticEnabled: false)
        let rows = try XCTUnwrap(exact["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String,"note-title"); XCTAssertEqual(exact["next_offset"] as? Int,1)
        XCTAssertEqual(exact["semantic"] as? String,"disabled")
        let typo = try AgentSearch.run(["query":"Registration pricnig"], database:db,semanticEnabled:false)
        XCTAssertEqual((typo["results"] as? [[String: Any]])?.count,2)
        XCTAssertThrowsError(try AgentSearch.run(["query":"x","after":"bad date"],database:db,semanticEnabled:false))
    }
    @MainActor func testNoteOwnsAttachedScreenshotAndConflictRollsBackImportedFile() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let root = try root(), assets = DocumentAssets(root: root.appendingPathComponent("assets")), note = Note(body:"Introduction")
        let image = try AgentMediaStore.canvas(size: CGSize(width: 80,height: 40)) { context in context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x:0,y:0,width:80,height:40)) }
        let source = root.appendingPathComponent("source.png"); try AgentImages.png(image).write(to:source)
        try db.write { try note.insert($0) }
        let result = try AgentNoteAssets.attach(["id":"note-"+note.id,"path":source.path,"alt":"Figure [one]"],database:db,assets:assets)
        let reference = try XCTUnwrap(result["asset_reference"] as? String), owned = try XCTUnwrap(assets.resolve(reference))
        XCTAssertTrue(try db.read { try Note.fetchOne($0,key:note.id)!.body.contains(reference) })
        XCTAssertTrue(FileManager.default.fileExists(atPath:owned.path))
        XCTAssertThrowsError(try AgentNoteAssets.attach(["id":"note-"+note.id,"path":source.path,"expected_updated_at":"stale"],database:db,assets:assets))
        XCTAssertEqual(assets.ownedFiles(documentID:"note-"+note.id).count,1)
        try FileManager.default.removeItem(at:source)
        XCTAssertTrue(FileManager.default.fileExists(atPath:owned.path))
    }
}
