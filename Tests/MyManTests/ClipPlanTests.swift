import XCTest
@testable import MyMan

final class ClipPlanTests: XCTestCase {
    func testA20SecondClipPlansToUnderTheCap() {
        let bitrate = ClipPlan.videoBitrate(durationSeconds: 20)
        let projected = bitrate * 20 / 8
        XCTAssertLessThanOrEqual(projected, ClipPlan.maximumBytes)
        XCTAssertGreaterThan(bitrate, 1_000_000, "a 20 s clip should still look reasonable")
    }
    func testShortClipsDoNotExceedTheBitrateCeiling() {
        XCTAssertEqual(ClipPlan.videoBitrate(durationSeconds: 1), ClipPlan.maximumBitrate)
    }
    func testFpsIsLimitedToTwelveToFifteen() throws {
        XCTAssertEqual(try ClipPlan.fps(nil), 15)
        XCTAssertEqual(try ClipPlan.fps(12), 12)
        XCTAssertThrowsError(try ClipPlan.fps(30))
        XCTAssertThrowsError(try ClipPlan.fps(10))
    }
    func testDurationIsOneToTwentySeconds() throws {
        XCTAssertEqual(try ClipPlan.duration(nil), 20)
        XCTAssertThrowsError(try ClipPlan.duration(0))
        XCTAssertThrowsError(try ClipPlan.duration(21))
    }
    func testSizeKeepsAspectWithEvenSidesAndCapsTheLongEdge() {
        let (w, h) = ClipPlan.size(width: 1920, height: 1080)
        XCTAssertEqual(w, 960); XCTAssertEqual(h, 540)
        let (tw, th) = ClipPlan.size(width: 301, height: 201)
        XCTAssertEqual(tw % 2, 0); XCTAssertEqual(th % 2, 0)
        XCTAssertLessThanOrEqual(max(tw, th), ClipPlan.maximumEdge)
    }
    func testResultSaysWhetherItIsWithinTheLimitAndHasNoAudio() {
        let result = ClipPlan.result(id: "c", path: "/c.mp4", posterPath: "/c.png", bytes: 3_000_000, durationMs: 20_000, width: 960, height: 540, fps: 15)
        XCTAssertEqual(result["within_limit"] as? Bool, true)
        XCTAssertEqual(result["audio"] as? Bool, false)
        XCTAssertEqual(result["poster_path"] as? String, "/c.png")
        XCTAssertEqual(ClipPlan.result(id: "c", path: "/c.mp4", posterPath: nil, bytes: 5_000_000, durationMs: 1, width: 1, height: 1, fps: 12)["within_limit"] as? Bool, false)
    }
}
