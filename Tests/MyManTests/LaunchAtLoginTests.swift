import XCTest
@testable import MyMan

final class LaunchAtLoginTests: XCTestCase {
    func testSeedRunsOnlyOnce() {
        let suite = "man-login-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLogin.seededKey))
        LaunchAtLogin.seedDefaultOnce(defaults)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLogin.seededKey))
        defaults.removePersistentDomain(forName: suite)
    }
}
