import XCTest
@testable import MyMan

/// A new install must not have any agent grant on. The first request then asks in context.
final class FreshInstallDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { super.setUp(); suite = "man-fresh-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    func testNoPresetOnFreshInstall() {
        XCTAssertNil(AgentAccessPreset.current(defaults))
    }

    func testSensitiveGrantsStartOff() {
        for group in ["capture", "markup", "recording", "library", "sharing", "control"] {
            guard let key = AgentConsent.keys[group] else { XCTFail("no key for \(group)"); continue }
            XCTAssertFalse(defaults.bool(forKey: key), "\(group) must be off on a fresh install")
        }
    }

    func testSharingStaysOffUntilFirstShare() {
        XCTAssertFalse(ShareFirstUse.confirmed(defaults))
    }
}
