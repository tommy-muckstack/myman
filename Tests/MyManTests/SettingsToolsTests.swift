import XCTest
@testable import MyMan

final class SettingsToolsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { super.setUp(); suite = "man-tools-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    func testExportNeverIncludesSecretOrAccountKeys() {
        let banned = ["token", "key", "secret", "password", "account", "workspace", "endpoint", "api"]
        for key in SettingsTools.exportable {
            for word in banned { XCTAssertFalse(key.lowercased().contains(word), "\(key) contains \(word)") }
        }
    }
    func testExportCarriesOnlySetKeys() {
        defaults.set("ask", forKey: AgentAccessPreset.key)
        let exported = SettingsTools.exportDictionary(defaults)
        XCTAssertEqual(exported[AgentAccessPreset.key] as? String, "ask")
        XCTAssertEqual(exported.count, 1)
    }
    func testResetRemovesOnlyTheResettableKeys() {
        defaults.set("ask", forKey: AgentAccessPreset.key)
        defaults.set("private-value", forKey: "anthropicAPIKey")
        SettingsTools.reset(defaults)
        XCTAssertNil(defaults.object(forKey: AgentAccessPreset.key))
        XCTAssertEqual(defaults.string(forKey: "anthropicAPIKey"), "private-value")
    }
}
