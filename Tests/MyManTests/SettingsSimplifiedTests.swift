import XCTest
@testable import MyMan

final class SettingsSimplifiedTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "man-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testCameraFindsPrivacyAndCapture() {
        let areas = Set(SettingsSearch.results(for: "camera").flatMap(\.areas))
        XCTAssertTrue(areas.contains(.privacy)); XCTAssertTrue(areas.contains(.capture))
    }
    func testRecordFindsRecording() {
        XCTAssertTrue(SettingsSearch.results(for: "record").contains { $0.title == "Recording" })
    }
    func testFolderFindsBrainFolderAndScreenshotFolder() {
        let titles = SettingsSearch.results(for: "folder").map(\.title)
        XCTAssertTrue(titles.contains("Your Brain folder")); XCTAssertTrue(titles.contains("Screenshot folder"))
    }
    func testEveryWordMustMatch() {
        XCTAssertTrue(SettingsSearch.results(for: "camera zebra").isEmpty)
        XCTAssertEqual(SettingsSearch.results(for: "  ").count, 0)
    }
    func testAgentSearchLandsOnAgents() {
        XCTAssertTrue(SettingsSearch.results(for: "agent").allSatisfy { $0.areas.contains(.agents) || $0.areas.contains(.brainFolder) || $0.areas.contains(.advanced) })
    }
    func testNoVisibleTextUsesInternalWords() {
        let banned = ["grant", "bridge", "sidecar", "manifest"]
        for entry in SettingsSearch.entries {
            for text in [entry.title] + entry.keywords {
                for word in banned { XCTAssertFalse(text.lowercased().contains(word), "\(text) contains \(word)") }
            }
        }
        for permission in PrivacyPermission.allCases {
            for text in [permission.title, permission.why] { for word in banned { XCTAssertFalse(text.lowercased().contains(word)) } }
        }
    }
    func testEachFixButtonOpensItsOwnPane() {
        let panes = PrivacyPermission.allCases.map { $0.settingsURL.absoluteString }
        XCTAssertEqual(Set(panes).count, 4)
        XCTAssertTrue(PrivacyPermission.camera.settingsURL.absoluteString.hasSuffix("Privacy_Camera"))
        XCTAssertTrue(PrivacyPermission.screenRecording.settingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }

    func testMigrationKeepsAnyGrantAsAskAndAllGrantsAsTrusted() {
        XCTAssertEqual(AgentAccessMigration.preset(grants: [:]), .off)
        XCTAssertEqual(AgentAccessMigration.preset(grants: ["capture": true]), .ask)
        XCTAssertEqual(AgentAccessMigration.preset(grants: ["capture": true, "markup": true, "recording": true, "library": true]), .trusted)
        XCTAssertEqual(AgentAccessMigration.preset(grants: ["capture": true, "sharing": true]), .ask, "sharing never makes a preset trusted")
    }
    func testFreshInstallIsNotTreatedAsExisting() {
        XCTAssertFalse(AgentAccessMigration.isExistingInstall(defaults))
        defaults.set(false, forKey: "agentCaptureEnabled")
        XCTAssertTrue(AgentAccessMigration.isExistingInstall(defaults))
    }

    func testPauseStopsEverythingAndResumeRestoresExactly() {
        defaults.set(true, forKey: "agentActionsEnabled"); defaults.set(true, forKey: "agentCaptureEnabled")
        defaults.set(false, forKey: "agentRecordingEnabled"); defaults.set(true, forKey: "agentFolderBridgeEnabled")
        PauseEverything.pause(defaults)
        XCTAssertTrue(PauseEverything.isPaused(defaults))
        XCTAssertFalse(defaults.bool(forKey: "agentActionsEnabled")); XCTAssertFalse(defaults.bool(forKey: "agentCaptureEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "agentFolderBridgeEnabled"))
        PauseEverything.resume(defaults)
        XCTAssertFalse(PauseEverything.isPaused(defaults))
        XCTAssertTrue(defaults.bool(forKey: "agentActionsEnabled")); XCTAssertTrue(defaults.bool(forKey: "agentCaptureEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "agentRecordingEnabled")); XCTAssertTrue(defaults.bool(forKey: "agentFolderBridgeEnabled"))
    }
    func testPauseTwiceKeepsTheFirstSnapshot() {
        defaults.set(true, forKey: "agentCaptureEnabled")
        PauseEverything.pause(defaults); PauseEverything.pause(defaults)
        PauseEverything.resume(defaults)
        XCTAssertTrue(defaults.bool(forKey: "agentCaptureEnabled"))
    }
    func testResumeLeavesUnsetKeysUnset() {
        PauseEverything.pause(defaults); PauseEverything.resume(defaults)
        XCTAssertNil(defaults.object(forKey: "agentControlEnabled"))
    }
}
