import AppKit
import XCTest
@testable import MyMan

final class RecordingBackdropColorTests: XCTestCase {
    func testCustomColorRoundTripsThroughDefaults() {
        let suite = "backdrop-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PolishOptions.saveCustomColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), defaults)
        let loaded = PolishOptions.savedCustomColor(defaults).usingColorSpace(.sRGB)!
        XCTAssertEqual(loaded.redComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(loaded.greenComponent, 0.4, accuracy: 0.001)
        XCTAssertEqual(loaded.blueComponent, 0.6, accuracy: 0.001)
    }

    func testMissingOrBadColorFallsBackToOcean() {
        let suite = "backdrop-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([2.0, 0.0, 0.0], forKey: PolishOptions.customColorKey)
        XCTAssertEqual(PolishOptions.savedCustomColor(defaults), BackdropStyle.ocean.colors![0])
    }

    func testBackdropStyleRoundTripsAndDefaultsToOcean() {
        let suite = "backdrop-style-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PolishOptions.savedBackdropStyle(defaults), .ocean)
        PolishOptions.saveBackdropStyle(.custom, defaults)
        XCTAssertEqual(PolishOptions.savedBackdropStyle(defaults), .custom)
    }
}
