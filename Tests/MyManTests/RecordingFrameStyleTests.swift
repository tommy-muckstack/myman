import AppKit
import XCTest
@testable import MyMan

final class RecordingFrameStyleTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "frame-style-\(UUID().uuidString)")
    }

    /// With nothing saved the frame is blue, as it was described to be.
    func testDefaultIsBlue() {
        let color = RecordingFrameStyle.color(defaults).usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(color.blueComponent, color.redComponent)
        XCTAssertGreaterThan(color.blueComponent, color.greenComponent)
    }

    /// A saved color comes back as the same color.
    func testSavedColorRoundTrips() {
        RecordingFrameStyle.save(NSColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1), defaults)
        let color = RecordingFrameStyle.color(defaults).usingColorSpace(.sRGB)!
        XCTAssertEqual(color.redComponent, 0.9, accuracy: 0.002)
        XCTAssertEqual(color.greenComponent, 0.4, accuracy: 0.002)
        XCTAssertEqual(color.blueComponent, 0.1, accuracy: 0.002)
    }
}
