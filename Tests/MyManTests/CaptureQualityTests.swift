import XCTest
@testable import MyMan

final class CaptureQualityTests: XCTestCase {
    func testDefaultIsBalanced() {
        let suite = "man-quality-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertEqual(CaptureQuality.current(defaults), .balanced)
        defaults.removePersistentDomain(forName: suite)
    }
    func testSmallNeverGoesAbove1200() {
        XCTAssertLessThanOrEqual(AgentDocImage.widths(for: .small).max() ?? 0, 1200)
    }
    func testBestAndBalancedNeverGoAbove2400() {
        XCTAssertLessThanOrEqual(AgentDocImage.widths(for: .best).max() ?? 0, 2400)
        XCTAssertLessThanOrEqual(AgentDocImage.widths(for: .balanced).max() ?? 0, 2400)
    }
    func testSmallFilesAreNotLargerThanBestForTheSameCapture() {
        let encode: (CGFloat) -> Data? = { width in Data(count: Int(width) * 1000) }
        let small = AgentDocImage.fit(width: 4000, height: 3000, quality: .small, encode: encode)
        let best = AgentDocImage.fit(width: 4000, height: 3000, quality: .best, encode: encode)
        XCTAssertNotNil(small); XCTAssertNotNil(best)
        XCTAssertLessThanOrEqual(small!.width, best!.width)
    }
}
