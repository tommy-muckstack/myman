import XCTest
@testable import MyMan

final class AgentQuickToolsTests: XCTestCase {
    @MainActor func testTimerOwnershipSessionGuardsAndHumanControls() async throws {
        let timer = QuickToolsModel()
        timer.onFinish = {}
        defer { timer.stop() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        func call(_ action: String, _ args: [String: Any] = [:], owner: String = "agent-a") async throws -> [String: Any] {
            try await AgentQuickTools.execute(action, args, timer: timer, reminders: store, owner: owner)
        }
        let result = try await call("timer.start", ["seconds": 600.0])
        let id = try XCTUnwrap(result["session_id"] as? String)
        XCTAssertEqual(result["state"] as? String, "running")
        do { _ = try await call("timer.start", ["seconds": 10.0]); XCTFail("Must not replace timer") } catch {}
        do { _ = try await call("timer.cancel", ["session_id": id], owner: "agent-b"); XCTFail("Must enforce owner") } catch {}
        _ = try await call("timer.pause", ["session_id": id])
        let resumed = try await call("timer.resume", ["session_id": id])
        XCTAssertEqual(resumed["session_id"] as? String, id)
        timer.stop() // Human can always dismiss an agent's widget.
        timer.start(seconds: 300)
        do { _ = try await call("timer.cancel", ["session_id": id]); XCTFail("Old ID must not cancel a new human timer") } catch {}
        XCTAssertTrue(timer.timerActive)
    }

    @MainActor func testReminderResultsPersistenceAndOwner() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "localReminders.v1") }
        let timer = QuickToolsModel()
        let store = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        let result = try await AgentQuickTools.execute("reminder.create", ["seconds": 600.0, "message": "Take pizza out"], timer: timer, reminders: store, owner: "agent-a")
        XCTAssertEqual(result["message"] as? String, "Take pizza out")
        XCTAssertEqual(result["requires_app_open"] as? Bool, true)
        let id = try XCTUnwrap(result["id"] as? String)
        let restored = ReminderStore(defaults: defaults, schedule: { _ in false }, cancelNotification: { _ in }, alert: {})
        XCTAssertEqual(restored.reminders.first?.agentOwner, "agent-a")
        do {
            _ = try await AgentQuickTools.execute("reminder.cancel", ["id": id], timer: timer, reminders: restored, owner: "agent-b")
            XCTFail("Must enforce owner")
        } catch {}
        _ = try await AgentQuickTools.execute("reminder.cancel", ["id": id], timer: timer, reminders: restored, owner: "agent-a")
        XCTAssertTrue(restored.reminders.isEmpty)
    }

    @MainActor func testToolEvaluationAndNativeBoundaryValidation() throws {
        XCTAssertEqual(AgentQuickTools.timestamp("2026-09-23T10:00:00-04:00"), AgentQuickTools.timestamp("2026-09-23T14:00:00.000Z"))
        XCTAssertNotNil(AgentQuickTools.timestamp("2026-09-23T14:00:00.500Z"))
        XCTAssertNil(AgentQuickTools.timestamp("tomorrow"))
        XCTAssertEqual(AgentQuickTools.evaluate("18% of 240")["value"] as? Double, 43.2)
        XCTAssertEqual((AgentQuickTools.evaluate("#fffffd")["palette"] as? [String])?.count, 4)
        XCTAssertEqual(AgentQuickTools.evaluate("timer 10m")["side_effects"] as? Bool, false)
        XCTAssertEqual(AgentQuickTools.evaluate("8am in Iceland")["source_zone"] as? String, "Atlantic/Reykjavik")
        let actions = try XCTUnwrap(AgentActions.catalog["actions"] as? [[String: Any]])
        let schema = try XCTUnwrap(actions.first { $0["name"] as? String == "timer.start" }?["inputSchema"] as? [String: Any])
        for seconds in [0.0, -1.0, 86401.0, .infinity] { XCTAssertThrowsError(try AgentSchema.validate(["seconds": seconds], schema: schema)) }
        try AgentSchema.validate(["seconds": 600], schema: schema)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertThrowsError(try AgentConsent.validate("timer.start", args: ["seconds": 600], defaults: defaults))
        defaults.set(true, forKey: "agentLibraryEnabled")
        defer { defaults.removeObject(forKey: "agentLibraryEnabled") }
        XCTAssertNoThrow(try AgentConsent.validate("timer.start", args: ["seconds": 600], defaults: defaults))
    }
}
