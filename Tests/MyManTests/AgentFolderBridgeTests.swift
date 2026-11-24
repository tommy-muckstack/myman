import XCTest
import Foundation
@testable import MyMan

/// The folder bridge against a temporary folder, a synthetic catalog and a
/// stand-in dispatcher. Nothing here touches the app, a Brain or a person.
final class AgentFolderBridgeTests: XCTestCase {
    private static let catalog: [[String: Any]] = [
        ["name": "app.status", "description": "Live app state.", "readOnly": true, "destructive": false, "permissions": [String]()],
        ["name": "note.create", "description": "Create a note.", "readOnly": false, "destructive": false, "permissions": ["library"]],
        ["name": "screenshot.capture", "description": "Capture a display.", "readOnly": false, "destructive": false, "permissions": ["capture"]],
        ["name": "recording.start", "description": "Start a recording.", "readOnly": false, "destructive": false, "permissions": ["recording"]],
        ["name": "recording.stop", "description": "Stop a recording.", "readOnly": false, "destructive": false, "permissions": [String]()],
        ["name": "clipboard.read", "description": "Read the clipboard.", "readOnly": true, "destructive": false, "permissions": [String]()],
        ["name": "item.delete", "description": "Delete an item.", "readOnly": false, "destructive": true, "permissions": ["library"]],
        ["name": "share.list", "description": "List shares.", "readOnly": true, "destructive": false, "permissions": ["sharing"]],
    ]

    @MainActor private final class Fixture {
        let folder: URL, root: URL, defaults: UserDefaults, suite: String
        var dispatched: [[String: Any]] = []
        var results: [String: Any] = [:]
        var refuse: AgentError?
        var prior: [String: [String: Any]] = [:]
        var asked: [AgentApprovalRequest] = []
        var answer: AgentApprovalDecision = .allowOnce
        var hold: CheckedContinuation<AgentApprovalDecision, Never>?
        var holds = false
        var clock = Date()
        var bridge: AgentFolderBridge!
        init(enabled: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-folder-bridge-" + UUID().uuidString).resolvingSymlinksInPath()
            root = folder.appendingPathComponent("agent")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            suite = "man-folder-bridge-test-" + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(enabled, forKey: AgentFolderBridge.enabledKey)
            bridge = AgentFolderBridge(root: root, defaults: defaults, hooks: .init(
                catalog: { AgentFolderBridgeTests.catalog },
                preflight: { [unowned self] _, _, _ in if let refuse = self.refuse { throw refuse }; return "Test agent" },
                dispatch: { [unowned self] request in
                    self.dispatched.append(request)
                    let id = request["id"] as! String
                    return ["ok": true, "job": ["id": id, "state": "succeeded", "result": self.results[id] ?? ["done": true]] as [String: Any]]
                },
                priorJob: { [unowned self] in self.prior[$0] },
                approve: { [unowned self] request, _ in
                    self.asked.append(request)
                    guard self.holds else { return self.answer }
                    return await withCheckedContinuation { self.hold = $0 }
                },
                artifactRoots: { [unowned self] in [self.folder] },
                appVersion: "9.9.9", launchID: "launch-fixture",
                now: { [unowned self] in self.clock }, pollInterval: .milliseconds(5)))
        }
        func finish() { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        @discardableResult func send(_ action: String, args: [String: Any] = [:], id: String = UUID().uuidString, created: Date? = nil) throws -> String {
            let body: [String: Any] = ["id": id, "action": action, "args": args, "created": ISO8601DateFormatter().string(from: created ?? clock)]
            try JSONSerialization.data(withJSONObject: body).write(to: root.appendingPathComponent("inbox/\(id).json"))
            return id
        }
        func outbox(_ id: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("outbox/\(id).json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func code(_ id: String) -> String? { (outbox(id)?["error"] as? [String: Any])?["code"] as? String }
        var pending: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path)) ?? []).filter { $0.hasSuffix(".json") } }
        var audit: [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("audit.log"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    // MARK: Rules

    func testRequestsMustBeWholeNamedByTheirIdAndRecent() throws {
        let id = UUID().uuidString, name = id + ".json", now = Date()
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let created = ISO8601DateFormatter().string(from: now)
        let request = try AgentFolderBridgePolicy.parse(data(["id": id, "action": "app.status", "created": created]), name: name)
        XCTAssertEqual(request.action, "app.status"); XCTAssertTrue(request.args.isEmpty); XCTAssertTrue(request.identity.isEmpty)
        XCTAssertEqual(try AgentFolderBridgePolicy.parse(data(["id": id, "action": "a", "args": ["k": 1], "created": now.timeIntervalSince1970, "credential": "t"]), name: name).identity["credential"] as? String, "t")
        for invalid: [String: Any] in [
            ["id": UUID().uuidString, "action": "app.status", "created": created],
            ["id": id, "created": created],
            ["id": id, "action": "app.status"],
            ["id": id, "action": "app.status", "created": "yesterday"],
            ["id": id, "action": "app.status", "created": created, "args": [1, 2]],
            ["id": id, "action": "app.status", "created": created, "shell": "echo bad"],
        ] { XCTAssertThrowsError(try AgentFolderBridgePolicy.parse(data(invalid), name: name)) { XCTAssertEqual(($0 as? AgentError)?.code, "INVALID_REQUEST") } }
        XCTAssertThrowsError(try AgentFolderBridgePolicy.parse(Data("{".utf8), name: name))
        XCTAssertThrowsError(try AgentFolderBridgePolicy.parse(data(["id": "x", "action": "a", "created": created]), name: "x.json"))
        XCTAssertFalse(AgentFolderBridgePolicy.isRequestName("." + name)); XCTAssertFalse(AgentFolderBridgePolicy.isRequestName(id + ".json.tmp"))
        XCTAssertFalse(AgentFolderBridgePolicy.isStale(now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(AgentFolderBridgePolicy.isStale(now.addingTimeInterval(-601), now: now))
        XCTAssertTrue(AgentFolderBridgePolicy.isStale(now.addingTimeInterval(601), now: now))
    }

    /// Run against the shipped catalog so a new action cannot slip past the prompt.
    @MainActor func testSensitiveActionsAskAndStoppingNeverDoes() throws {
        let actions = try XCTUnwrap(AgentActions.catalog["actions"] as? [[String: Any]])
        func group(_ name: String, _ args: [String: Any] = [:]) throws -> String? {
            AgentFolderBridgePolicy.approvalGroup(action: name, info: try XCTUnwrap(actions.first { $0["name"] as? String == name }, name), args: args)
        }
        for (name, expected) in ["screenshot.capture": "capture", "screenshot.capture_markup": "capture", "windows.list": "capture", "capture.scroll.start": "capture",
                                 "recording.start": "recording", "recording.export": "recording", "meeting.start": "recording", "meeting.notes": "recording", "dictation.start": "recording",
                                 "clipboard.read": "clipboard", "clipboard.write": "clipboard", "demo.run": "control", "share.publish": "sharing",
                                 "item.delete": "delete", "task.delete": "delete", "history.clear": "delete", "brief.delete": "delete"] {
            XCTAssertEqual(try group(name), expected, name)
        }
        XCTAssertEqual(try group("screenshot.edit", ["clipboard": true]), "clipboard")
        for name in ["app.status", "app.doctor", "note.create", "item.read", "capture.search", "share.list", "screenshot.edit"] { XCTAssertNil(try group(name), name) }
        for name in AgentConsent.cleanup where actions.contains(where: { $0["name"] as? String == name }) { XCTAssertNil(try group(name), name) }
        // Every action that needs the capture, recording or control grant asks, apart from stopping.
        for info in actions {
            let name = try XCTUnwrap(info["name"] as? String), grants = Set(info["permissions"] as? [String] ?? [])
            guard !AgentConsent.cleanup.contains(name), !grants.isDisjoint(with: ["capture", "recording", "control"]) || info["destructive"] as? Bool == true else { continue }
            XCTAssertEqual(AgentFolderBridgePolicy.tier(action: name, info: info), "approval", name)
        }
        let listed = AgentFolderBridgePolicy.manifestActions(actions)
        XCTAssertEqual(listed.count, actions.count)
        XCTAssertEqual(listed.first { $0["name"] as? String == "app.status" }?["tier"] as? String, "open")
        XCTAssertEqual(listed.first { $0["name"] as? String == "note.create" }?["tier"] as? String, "grant")
        XCTAssertEqual(listed.first { $0["name"] as? String == "item.delete" }?["requires_confirm"] as? Bool, true)
        XCTAssertNotNil(listed.first { $0["name"] as? String == "note.create" }?["inputSchema"])
    }

    func testOnlyPathKeysNameFilesAndInlineImagesLeaveTheResult() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result: [String: Any] = ["id": "shot-1", "path": "/captures/a.png", "body": "/Users/someone/.ssh/id_rsa", "title": "/etc/passwd",
                                     "attachment": ["path": "/captures/a.png", "preview_path": "/cache/a.png", "brain_path": "screenshots/a.md"] as [String: Any],
                                     "recovery_paths": ["/captures/part.mov"], "image": ["mimeType": "image/png", "data": png.base64EncodedString()]]
        let found = AgentFolderBridgePolicy.extract(result, action: "screenshot.image", folder: "artifacts/x")
        XCTAssertEqual(found.files.map(\.source).sorted(), ["/cache/a.png", "/captures/a.png", "/captures/part.mov"])
        XCTAssertEqual(Set(found.files.map(\.name)).count, 3, "same base names stay distinct")
        let cleaned = try XCTUnwrap(found.result as? [String: Any]), image = try XCTUnwrap(cleaned["image"] as? [String: Any])
        XCTAssertNil(image["data"]); XCTAssertEqual(image["artifact"] as? String, "artifacts/x/inline.png")
        XCTAssertEqual(found.blobs.first?.data, png)
        XCTAssertEqual(cleaned["body"] as? String, "/Users/someone/.ssh/id_rsa")
        let notes = AgentFolderBridgePolicy.extract(["id": "meeting-1", "notes": "## Summary"], action: "meeting.notes", folder: "artifacts/y")
        XCTAssertEqual(notes.blobs.map(\.name), ["notes.md"]); XCTAssertEqual((notes.result as? [String: Any])?["notes"] as? String, "## Summary")
    }

    func testFilesAreCopiedOnlyFromSavedMediaFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("man-artifacts-" + UUID().uuidString).resolvingSymlinksInPath()
        let saved = base.appendingPathComponent("saved"), outside = base.appendingPathComponent("outside"), target = base.appendingPathComponent("out")
        for folder in [saved, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("image".utf8).write(to: saved.appendingPathComponent("shot.png"))
        try Data("key".utf8).write(to: saved.appendingPathComponent("id_rsa"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: saved.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        let files = [("shot.png", saved), ("id_rsa", saved), ("secret.png", outside), ("link.png", saved), ("gone.png", saved)].map { (source: $0.1.appendingPathComponent($0.0).path, name: $0.0) }
        let copied = AgentFolderBridgePolicy.materialize(files: files, blobs: [(data: Data("notes".utf8), name: "notes.md")], into: target, relative: "artifacts/id", roots: [saved.path])
        XCTAssertEqual(copied.written.sorted(), ["artifacts/id/notes.md", "artifacts/id/shot.png"])
        XCTAssertEqual(Set(copied.skipped.compactMap { $0["name"] }), ["id_rsa", "secret.png", "link.png", "gone.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(), ["notes.md", "shot.png"])
    }

    // MARK: Watcher and dispatcher

    @MainActor func testOffMeansNoFolderNoAnswerAndNothingRuns() async throws {
        let fixture = try Fixture(enabled: false); defer { fixture.finish() }
        fixture.bridge.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path), "a bridge that is off creates nothing")
        // A folder left from when it was on is not served either.
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        let id = try fixture.send("app.status")
        fixture.bridge.scan(); await fixture.bridge.handle(id + ".json")
        XCTAssertTrue(fixture.dispatched.isEmpty); XCTAssertNil(fixture.outbox(id)); XCTAssertEqual(fixture.pending, [id + ".json"])
        // The master switch turns the bridge off as well.
        fixture.defaults.set(true, forKey: AgentFolderBridge.enabledKey); fixture.defaults.set(false, forKey: "agentActionsEnabled")
        XCTAssertFalse(fixture.bridge.enabled)
        fixture.bridge.reconcile(); await fixture.bridge.handle(id + ".json")
        XCTAssertTrue(fixture.dispatched.isEmpty); XCTAssertNil(fixture.outbox(id))
    }

    @MainActor func testAnOpenActionRunsThroughTheDispatcherAndIsLogged() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["enabled"] as? Bool, true); XCTAssertEqual(manifest["app_version"] as? String, "9.9.9")
        XCTAssertEqual((manifest["actions"] as? [[String: Any]])?.count, Self.catalog.count)
        XCTAssertNotNil(try? Data(contentsOf: fixture.root.appendingPathComponent("heartbeat.json")))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent(".gitignore"), encoding: .utf8), "*\n")
        let id = try fixture.send("app.status")
        fixture.results[id] = ["version": "9.9.9"]
        await fixture.bridge.handle(id + ".json")
        let reply = try XCTUnwrap(fixture.outbox(id))
        XCTAssertEqual(reply["ok"] as? Bool, true); XCTAssertEqual((reply["result"] as? [String: Any])?["version"] as? String, "9.9.9")
        XCTAssertEqual(reply["artifacts"] as? [String], []); XCTAssertEqual(reply["action"] as? String, "app.status")
        XCTAssertTrue(fixture.pending.isEmpty, "the request is removed once answered")
        XCTAssertTrue(fixture.asked.isEmpty)
        XCTAssertEqual(fixture.dispatched.first?["method"] as? String, "invoke"); XCTAssertEqual(fixture.dispatched.first?["id"] as? String, id)
        XCTAssertEqual(fixture.audit.compactMap { $0["event"] as? String }, ["request", "result"])
    }

    @MainActor func testACaptureWaitsForThePersonThenCompletes() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile(); fixture.holds = true
        let shot = fixture.folder.appendingPathComponent("capture.png"); try Data("pixels".utf8).write(to: shot)
        let id = try fixture.send("screenshot.capture", args: ["display": "main"])
        fixture.results[id] = ["id": "shot-1", "path": shot.path]
        let work = Task { @MainActor in await fixture.bridge.handle(id + ".json") }
        for _ in 0 ..< 400 where fixture.hold == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fixture.code(id), "AWAITING_USER"); XCTAssertEqual(fixture.outbox(id)?["pending"] as? Bool, true)
        XCTAssertTrue(fixture.dispatched.isEmpty, "nothing runs before the answer")
        XCTAssertEqual(fixture.asked.first?.group, "capture"); XCTAssertEqual(fixture.asked.first?.requester, "Test agent"); XCTAssertEqual(fixture.asked.first?.canRemember, true)
        try XCTUnwrap(fixture.hold).resume(returning: .allowOnce); await work.value
        let reply = try XCTUnwrap(fixture.outbox(id))
        XCTAssertEqual(reply["ok"] as? Bool, true); XCTAssertNil(reply["pending"])
        XCTAssertEqual(reply["artifacts"] as? [String], ["artifacts/\(id)/capture.png"])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("artifacts/\(id)/capture.png")), Data("pixels".utf8))
        XCTAssertEqual(fixture.audit.compactMap { $0["event"] as? String }, ["request", "awaiting_user", "approved", "result"])
        // Allow once is once: the next capture asks again.
        fixture.holds = false; fixture.answer = .deny
        let second = try fixture.send("screenshot.capture")
        await fixture.bridge.handle(second + ".json")
        XCTAssertEqual(fixture.code(second), "USER_DENIED"); XCTAssertEqual(fixture.dispatched.count, 1)
    }

    @MainActor func testTenMinutesCoversOneKindAndDeletesAlwaysAsk() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile(); fixture.answer = .allowForTenMinutes
        for _ in 0 ..< 2 { await fixture.bridge.handle(try fixture.send("recording.start") + ".json") }
        XCTAssertEqual(fixture.asked.count, 1); XCTAssertEqual(fixture.dispatched.count, 2)
        await fixture.bridge.handle(try fixture.send("screenshot.capture") + ".json")
        XCTAssertEqual(fixture.asked.count, 2, "another kind asks again")
        for _ in 0 ..< 2 { await fixture.bridge.handle(try fixture.send("item.delete", args: ["id": "x", "confirm": true]) + ".json") }
        XCTAssertEqual(fixture.asked.count, 4); XCTAssertEqual(fixture.asked.last?.canRemember, false)
        fixture.clock = fixture.clock.addingTimeInterval(601)
        await fixture.bridge.handle(try fixture.send("recording.start") + ".json")
        XCTAssertEqual(fixture.asked.count, 5, "the ten minutes end")
        // Stopping is never held back.
        let before = fixture.asked.count
        await fixture.bridge.handle(try fixture.send("recording.stop", args: ["session_id": "s"]) + ".json")
        XCTAssertEqual(fixture.asked.count, before)
    }

    @MainActor func testRefusalsNeverReachTheDispatcherOrThePerson() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile()
        let stale = try fixture.send("app.status", created: fixture.clock.addingTimeInterval(-900))
        await fixture.bridge.handle(stale + ".json")
        XCTAssertEqual(fixture.code(stale), "STALE_REQUEST")
        let unknown = try fixture.send("shell.run", args: ["command": "id"])
        await fixture.bridge.handle(unknown + ".json")
        XCTAssertEqual(fixture.code(unknown), "UNKNOWN_ACTION")
        fixture.refuse = AgentError("AGENT_DISABLED", "Enable capture access in My Man Settings → Agents for this action.")
        let denied = try fixture.send("screenshot.capture")
        await fixture.bridge.handle(denied + ".json")
        XCTAssertEqual(fixture.code(denied), "AGENT_DISABLED")
        XCTAssertNotNil((fixture.outbox(denied)?["error"] as? [String: Any])?["hint"])
        fixture.refuse = nil
        let broken = UUID().uuidString
        try Data("{not json".utf8).write(to: fixture.root.appendingPathComponent("inbox/\(broken).json"))
        await fixture.bridge.handle(broken + ".json")
        XCTAssertEqual(fixture.code(broken), "INVALID_REQUEST")
        try Data("{}".utf8).write(to: fixture.root.appendingPathComponent("inbox/not-a-uuid.json"))
        await fixture.bridge.handle("not-a-uuid.json")
        XCTAssertNil(fixture.outbox("not-a-uuid"), "only a UUID names an outbox file")
        XCTAssertTrue(fixture.dispatched.isEmpty); XCTAssertTrue(fixture.asked.isEmpty); XCTAssertTrue(fixture.pending.isEmpty)
    }

    @MainActor func testAnIdRunsOnceAndAnEarlierResultIsNeverReplaced() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile()
        let id = try fixture.send("app.status")
        fixture.results[id] = ["first": true]
        await fixture.bridge.handle(id + ".json")
        try fixture.send("note.create", args: ["body": "again"], id: id)
        await fixture.bridge.handle(id + ".json")
        XCTAssertEqual((fixture.outbox(id)?["result"] as? [String: Any])?["first"] as? Bool, true)
        XCTAssertEqual(fixture.dispatched.count, 1); XCTAssertTrue(fixture.pending.isEmpty)
        XCTAssertEqual(fixture.audit.last?["code"] as? String, "ID_ALREADY_USED")
        // The result was collected and removed, and the id is still spent.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("outbox/\(id).json"))
        try fixture.send("app.status", id: id)
        await fixture.bridge.handle(id + ".json")
        XCTAssertEqual(fixture.code(id), "ID_ALREADY_USED"); XCTAssertEqual(fixture.dispatched.count, 1)
        // A receipt from an earlier launch spends the id too, and interrupted work is reported, not replayed.
        let earlier = UUID().uuidString, interrupted = UUID().uuidString
        fixture.prior[earlier] = ["id": earlier, "state": "succeeded"]
        fixture.prior[interrupted] = ["id": interrupted, "state": "interrupted", "error": ["code": "APP_RESTARTED", "message": "Work was interrupted."]]
        try fixture.send("app.status", id: earlier); await fixture.bridge.handle(earlier + ".json")
        try fixture.send("app.status", id: interrupted); await fixture.bridge.handle(interrupted + ".json")
        XCTAssertEqual(fixture.code(earlier), "ID_ALREADY_USED"); XCTAssertEqual(fixture.code(interrupted), "APP_RESTARTED")
        XCTAssertEqual(fixture.dispatched.count, 1)
    }

    @MainActor func testTheWatcherPicksUpARenamedRequest() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile()
        let id = UUID().uuidString, inbox = fixture.root.appendingPathComponent("inbox")
        let body: [String: Any] = ["id": id, "action": "app.status", "args": [String: Any](), "created": ISO8601DateFormatter().string(from: fixture.clock)]
        // Half-written under a dot name: the app must not read it.
        try JSONSerialization.data(withJSONObject: body).write(to: inbox.appendingPathComponent(".\(id).json.tmp"))
        fixture.bridge.scan()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(fixture.outbox(id)); XCTAssertTrue(fixture.dispatched.isEmpty)
        try FileManager.default.moveItem(at: inbox.appendingPathComponent(".\(id).json.tmp"), to: inbox.appendingPathComponent("\(id).json"))
        for _ in 0 ..< 600 where fixture.outbox(id) == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fixture.outbox(id)?["ok"] as? Bool, true, "the folder event alone starts the request")
    }

    @MainActor func testTurningTheBridgeOffStopsServingAndSaysSo() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        fixture.bridge.reconcile()
        fixture.defaults.set(false, forKey: AgentFolderBridge.enabledKey); fixture.bridge.reconcile()
        XCTAssertFalse(fixture.bridge.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("heartbeat.json").path))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["enabled"] as? Bool, false); XCTAssertNotNil(manifest["hint"])
        let id = try fixture.send("app.status")
        fixture.bridge.scan(); await fixture.bridge.handle(id + ".json")
        XCTAssertNil(fixture.outbox(id)); XCTAssertTrue(fixture.dispatched.isEmpty)
    }

    @MainActor func testALinkedFolderIsRefused() async throws {
        let fixture = try Fixture(); defer { fixture.finish() }
        let elsewhere = fixture.folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("outbox"), withDestinationURL: elsewhere)
        fixture.bridge.reconcile()
        XCTAssertFalse(fixture.bridge.running)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }
}
