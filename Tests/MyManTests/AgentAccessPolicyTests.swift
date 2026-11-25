import XCTest
@testable import MyMan

@MainActor final class AgentAccessPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "man-access-policy-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOffTurnsEverythingOff() {
        AgentAccessPreset.ask.apply(defaults)
        AgentAccessPreset.off.apply(defaults)
        XCTAssertEqual(AgentAccessPreset.current(defaults), .off)
        XCTAssertFalse(defaults.bool(forKey: "agentActionsEnabled"))
        XCTAssertFalse(defaults.bool(forKey: AgentFolderBridge.enabledKey))
        for grant in AgentConsent.keys.keys { XCTAssertFalse(defaults.bool(forKey: AgentConsent.keys[grant]!), grant) }
    }

    func testAskTurnsOnTheBridgeAndPresetGrantsButNotSharingOrControl() {
        AgentAccessPreset.ask.apply(defaults)
        XCTAssertEqual(AgentAccessPreset.current(defaults), .ask)
        XCTAssertTrue(defaults.bool(forKey: AgentFolderBridge.enabledKey))
        for grant in ["capture", "markup", "recording", "library"] { XCTAssertTrue(defaults.bool(forKey: AgentConsent.keys[grant]!), grant) }
        XCTAssertFalse(defaults.bool(forKey: AgentConsent.keys["sharing"]!))
        XCTAssertFalse(defaults.bool(forKey: AgentConsent.keys["control"]!))
    }

    func testTrustedSkipsOnlyCaptureAndRecordingPrompts() {
        AgentAccessPreset.trusted.apply(defaults)
        XCTAssertEqual(AgentAccessPolicy.verdict(action: "screenshot.capture", group: "capture", requester: "Claude", defaults), .approved(by: "trusted_preset", ruleID: nil))
        XCTAssertEqual(AgentAccessPolicy.verdict(action: "recording.start", group: "recording", requester: "Claude", defaults), .approved(by: "trusted_preset", ruleID: nil))
        for group in ["clipboard", "control", "sharing", "delete"] {
            XCTAssertEqual(AgentAccessPolicy.verdict(action: "x", group: group, requester: "Claude", defaults), .ask, group)
        }
    }

    func testRulesAreScopedToOneAgentAndOneAction() throws {
        let rule = try XCTUnwrap(AgentRules.add(requester: "Claude", action: "screenshot.capture", group: "capture", created: "2026-11-24T10:00:00.000Z", defaults))
        XCTAssertEqual(AgentAccessPolicy.verdict(action: "screenshot.capture", group: "capture", requester: "Claude", defaults), .approved(by: "always_allow", ruleID: rule.id))
        XCTAssertEqual(AgentAccessPolicy.verdict(action: "screenshot.capture", group: "capture", requester: "Other agent", defaults), .ask)
        XCTAssertEqual(AgentAccessPolicy.verdict(action: "screenshot.window", group: "capture", requester: "Claude", defaults), .ask)
    }

    func testDeleteClipboardAndSharingAreNeverRemembered() {
        for group in ["delete", "clipboard", "sharing"] {
            XCTAssertNil(AgentRules.add(requester: "Claude", action: "a", group: group, created: "now", defaults), group)
        }
        XCTAssertTrue(AgentRules.all(defaults).isEmpty)
    }

    func testRevokingAGrantRemovesItsRulesAndRevokeAllClearsTheRest() throws {
        _ = AgentRules.add(requester: "Claude", action: "screenshot.capture", group: "capture", created: "now", defaults)
        _ = AgentRules.add(requester: "Claude", action: "recording.start", group: "recording", created: "now", defaults)
        AgentRules.removeGroup("capture", defaults)
        XCTAssertEqual(AgentRules.all(defaults).map(\.action), ["recording.start"])
        AgentRules.removeAll(defaults)
        XCTAssertTrue(AgentRules.all(defaults).isEmpty)
    }

    func testRulesRoundTripThroughPreferencesText() throws {
        let rule = try XCTUnwrap(AgentRules.add(requester: "Claude", action: "screenshot.capture", group: "capture", created: "2026-11-24T10:00:00.000Z", defaults))
        XCTAssertEqual(AgentRules.decode(defaults.string(forKey: AgentRules.key) ?? ""), [rule])
        XCTAssertEqual(AgentRules.decode("not json"), [])
    }

    func testGrantTitlesNameTheGrantInPlainWords() {
        XCTAssertEqual(AgentAccessPolicy.grantTitle("recording"), "Recording")
        XCTAssertEqual(AgentAccessPolicy.grantTitle("capture"), "Screen capture")
    }
}
