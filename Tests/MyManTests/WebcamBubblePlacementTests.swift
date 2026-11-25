import AppKit
import XCTest
@testable import MyMan

@MainActor
final class WebcamBubblePlacementTests: XCTestCase {
    private let region = NSRect(x: 0, y: 0, width: 1000, height: 800)

    /// A bubble dragged inside the region keeps its spot for the next take.
    func testSavedSpotInsideRegionIsKept() {
        let saved = NSRect(x: 700, y: 100, width: 240, height: 240)
        XCTAssertEqual(WebcamBubble.savedFrame(saved, fitting: region), saved)
    }

    /// A spot from an old, different region falls back to the default corner.
    func testSpotOutsideRegionIsDropped() {
        let saved = NSRect(x: 2000, y: 2000, width: 240, height: 240)
        XCTAssertNil(WebcamBubble.savedFrame(saved, fitting: region))
    }

    /// Full-screen takes have no region to check, so the saved spot is used as is.
    func testSavedSpotKeptWithoutRegion() {
        let saved = NSRect(x: 50, y: 60, width: 240, height: 240)
        XCTAssertEqual(WebcamBubble.savedFrame(saved, fitting: nil), saved)
    }

    /// Nothing saved yet means the default corner.
    func testNothingSavedUsesDefault() {
        XCTAssertNil(WebcamBubble.savedFrame(nil, fitting: region))
    }
}
