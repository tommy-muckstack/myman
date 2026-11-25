import XCTest
@testable import MyMan

final class CameraSelectionTests: XCTestCase {
    func testSavedChoiceRoundTripsAndEmptyMeansAutomatic() {
        let suite = "camera-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CameraSelection.savedUID(defaults), "")
        CameraSelection.save("iphone-abc", defaults)
        XCTAssertEqual(CameraSelection.savedUID(defaults), "iphone-abc")
        XCTAssertNil(CameraSelection.selectedDevice(UserDefaults(suiteName: "unused-\(UUID().uuidString)")!))
    }
}
