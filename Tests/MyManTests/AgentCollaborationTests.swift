import XCTest
import GRDB
@testable import MyMan

final class AgentCollaborationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("man-collab-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func fixture(_ revision: Int = 1) -> CaptureItem {
        CaptureItem(id: "note-fixture", kind: "note", sourceID: "fixture", rawTitle: "Synthetic", generatedTitle: "", userTitle: "", body: "Synthetic", summary: "", metadata: "", sourcePath: "", capturedAt: Date(), modifiedAt: Date(), pinned: false, excluded: false, revision: revision)
    }
    @MainActor func testCredentialsAreHashedRevocableAndMachineBound() throws {
        let root = try root(), registry = AgentIdentity(root: root)
        let (agent, token) = try registry.issue(name: "Capture Agent", scopes: ["library"])
        XCTAssertTrue(registry.required)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("AgentIdentity/identities.json")).contains(token))
        let principal = try registry.authenticate(["credential": token, "machine_id": registry.machine["id"]!])
        XCTAssertEqual(principal.id, agent.id)
        XCTAssertThrowsError(try registry.authenticate(["agent_id": agent.id]))
        XCTAssertThrowsError(try registry.authenticate(["credential": token, "machine_id": "wrong"]))
        XCTAssertThrowsError(try registry.validate(principal, action: "recording.start"))
        let reloaded = AgentIdentity(root: root)
        XCTAssertEqual(try reloaded.authenticate(["credential": token]).id, principal.id)
        try reloaded.revoke(principal.id)
        XCTAssertThrowsError(try reloaded.authenticate(["credential": token]))
        XCTAssertThrowsError(try reloaded.validate(principal, action: "note.create"))
    }
    @MainActor func testCorruptIdentityRegistryFailsClosed() throws {
        let root = try root(), registry = AgentIdentity(root: root)
        _ = try registry.issue(name: "Capture Agent", scopes: [])
        try Data("broken".utf8).write(to: root.appendingPathComponent("AgentIdentity/identities.json"))
        XCTAssertThrowsError(try AgentIdentity(root: root).authenticate([:]))
    }
    @MainActor func testBundlesHandoffsRevisionsAndDeletionLifecycle() throws {
        let root = try root(), a = AgentPrincipal(id: "a", name: "Capture Agent", scopes: ["library"]), b = AgentPrincipal(id: "b", name: "Design", scopes: ["library"])
        var item: CaptureItem? = fixture()
        let store = AgentCollaboration(root: root, lookup: { _ in item }, registered: { ["a", "b"].contains($0) })
        let bundle = try AgentContext.$principal.withValue(a) { try store.execute("bundle.create", ["title": "Demo", "item_ids": ["note-fixture"], "members": ["b"]]) as! [String: Any] }
        let id = bundle["id"] as! String
        try AgentContext.$principal.withValue(a) { XCTAssertThrowsError(try store.execute("bundle.delete", ["id": id, "expected_revision": 1, "confirm": false])) }
        let handoff = try AgentContext.$principal.withValue(a) { try store.execute("handoff.create", ["bundle_id": id, "recipient": "b", "instruction": "Annotate the reference"]) as! [String: Any] }
        let hid = handoff["id"] as! String
        try AgentContext.$principal.withValue(a) {
            XCTAssertThrowsError(try store.execute("handoff.update", ["id": hid, "expected_revision": 1, "state": "accepted"]))
        }
        try AgentContext.$principal.withValue(b) {
            XCTAssertThrowsError(try store.execute("bundle.update", ["id": id, "expected_revision": 1, "members": ["b"]]))
            _ = try store.execute("handoff.update", ["id": hid, "expected_revision": 1, "state": "accepted"])
            XCTAssertThrowsError(try store.execute("handoff.update", ["id": hid, "expected_revision": 1, "state": "completed"]))
            _ = try store.execute("handoff.update", ["id": hid, "expected_revision": 2, "state": "completed", "output_ids": ["note-fixture"]])
            _ = try store.execute("bundle.update", ["id": id, "expected_revision": 1, "title": "Reviewed"])
        }
        try AgentContext.$principal.withValue(a) {
            XCTAssertThrowsError(try store.execute("bundle.update", ["id": id, "expected_revision": 1, "title": "Stale"]))
            item?.revision = 2
            let read = try store.execute("bundle.read", ["id": id]) as! [String: Any]
            XCTAssertEqual((read["items"] as! [[String: Any]])[0]["status"] as? String, "changed")
            let events = try store.execute("collaboration.events", [:]) as! [String: Any]
            XCTAssertTrue((events["events"] as! [[String: Any]]).contains { $0["type"] as? String == "handoff.completed" })
        }
        let outsider = AgentPrincipal(id: "c", name: "Other", scopes: ["library"])
        try AgentContext.$principal.withValue(outsider) { XCTAssertThrowsError(try store.execute("bundle.read", ["id": id])) }
        let restored = AgentCollaboration(root: root, lookup: { _ in item }, registered: { _ in true })
        try AgentContext.$principal.withValue(a) { XCTAssertEqual((try restored.execute("bundle.list", [:]) as! [[String: Any]]).count, 1) }
        item = nil; restored.purge(itemID: "note-fixture")
        try AgentContext.$principal.withValue(b) {
            XCTAssertEqual((try restored.execute("bundle.list", [:]) as! [[String: Any]]).count, 0)
            XCTAssertEqual((try restored.execute("handoff.list", [:]) as! [[String: Any]]).count, 0)
        }
    }
    @MainActor func testLeasesFenceOldOwnersAndSessionsTransferExplicitly() throws {
        let a = AgentPrincipal(id: "a", name: "Capture Agent", scopes: []), b = AgentPrincipal(id: "b", name: "Design", scopes: [])
        let store = AgentCollaboration(root: try root(), registered: { _ in true })
        let lease = try AgentContext.$principal.withValue(a) { try store.execute("lease.acquire", ["resource": "clipboard", "seconds": 60.0]) as! [String: Any] }
        try AgentContext.$principal.withValue(b) {
            XCTAssertThrowsError(try store.begin(resource: "clipboard", leaseID: lease["id"] as? String))
            XCTAssertThrowsError(try store.execute("lease.acquire", ["resource": "clipboard"]))
        }
        try AgentContext.$principal.withValue(a) {
            try store.begin(resource: "clipboard", leaseID: lease["id"] as? String)
            XCTAssertThrowsError(try store.execute("lease.acquire", ["resource": "clipboard"]))
            store.end(resource: "clipboard")
            _ = try store.execute("lease.release", ["resource": "clipboard", "lease_id": lease["id"]!])
            XCTAssertThrowsError(try store.begin(resource: "clipboard", leaseID: lease["id"] as? String))
            try store.ownSession("session")
        }
        try AgentContext.$principal.withValue(b) { XCTAssertThrowsError(try store.checkSession("session")) }
        try AgentContext.$principal.withValue(a) { _ = try store.execute("session.transfer", ["session_id": "session", "recipient": "b"]) }
        try AgentContext.$principal.withValue(a) { XCTAssertThrowsError(try store.checkSession("session")) }
        try AgentContext.$principal.withValue(b) { try store.checkSession("session") }
    }
    func testTaskVersionCheckIsAtomicAndDetectsHumanEdits() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let task = TaskItem(id: "fixture", title: "Original", source: "manual", done: false, createdAt: Date())
        try db.write { try task.insert($0) }
        let version = try db.read { try AgentVersions.version("task", id: task.id, db: $0) }
        try db.write { try $0.execute(sql: "UPDATE task SET title='Human edit' WHERE id=?", arguments: [task.id]) }
        XCTAssertThrowsError(try db.write { try AgentVersions.check("task", id: task.id, expected: version, db: $0); try $0.execute(sql: "DELETE FROM task WHERE id=?", arguments: [task.id]) })
        XCTAssertEqual(try db.read { try TaskItem.fetchOne($0, key: task.id)?.title }, "Human edit")
    }
}
