import XCTest
@testable import MyMan

final class NarrationPlanTests: XCTestCase {
    func testAFiveMinuteTakeAtTheSpecBitratesIsOverTheCapSoItReencodes() {
        // 450 kbps + 64 kbps for 300 s is about 19 MB, which is over 15 MB, so the re-encode must bring it under.
        let bytes = (NarrationPlan.videoBitrate + NarrationPlan.audioBitrate) * 300 / 8
        XCTAssertGreaterThan(bytes, NarrationPlan.maximumBytes)
        let bitrate = NarrationPlan.reencodeVideoBitrate(durationSeconds: 300, bytes: bytes)
        XCTAssertNotNil(bitrate)
        let projected = (bitrate! + NarrationPlan.audioBitrate) * 300 / 8
        XCTAssertLessThanOrEqual(projected, NarrationPlan.maximumBytes)
    }
    func testATakeUnderTheCapIsNotReencoded() {
        XCTAssertNil(NarrationPlan.reencodeVideoBitrate(durationSeconds: 30, bytes: 2_000_000))
    }
    func testVideoBitrateNeverDropsBelowTheFloor() {
        XCTAssertEqual(NarrationPlan.reencodeVideoBitrate(durationSeconds: 3600, bytes: 200_000_000), NarrationPlan.minimumVideoBitrate)
    }
    func testResultCarriesTheFieldsAnAgentNeeds() {
        let result = NarrationPlan.result(id: "n1", startedAtEpochMs: 1_763_000_000_123, durationMs: 30_000, path: "/x/n1.mp4", bytes: 1_000, reencodedVideoBitrate: nil)
        XCTAssertEqual(result["startedAtEpochMs"] as? Int64, 1_763_000_000_123)
        XCTAssertEqual(result["durationMs"] as? Int, 30_000)
        XCTAssertEqual(result["path"] as? String, "/x/n1.mp4")
        XCTAssertEqual(result["bytes"] as? Int, 1_000)
        XCTAssertEqual(result["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(result["within_limit"] as? Bool, true)
        XCTAssertEqual(result["reencoded"] as? Bool, false)
    }
    func testCountdownIsThreeTwoOne() {
        XCTAssertEqual(NarrationPlan.countdownSeconds, [3, 2, 1])
    }

    func testPersonalProfileHasNoSizeCapAndNeverReencodes() {
        XCTAssertNil(NarrationPlan.personal.maximumBytes)
        XCTAssertNil(NarrationPlan.reencodeVideoBitrate(durationSeconds: 300, bytes: 900_000_000, profile: NarrationPlan.personal))
    }

    func testAgentProfileKeepsItsFifteenMegabyteCap() {
        XCTAssertEqual(NarrationPlan.agent.maximumBytes, 15_000_000)
        XCTAssertEqual(NarrationPlan.agent.width, 480)
        XCTAssertNotNil(NarrationPlan.reencodeVideoBitrate(durationSeconds: 300, bytes: 900_000_000, profile: NarrationPlan.agent))
    }

    func testPersonalResultReportsTheHighQualitySettings() {
        let result = NarrationPlan.result(id: "n2", startedAtEpochMs: 1, durationMs: 1000, path: "/x", bytes: 900_000_000, reencodedVideoBitrate: nil, profile: NarrationPlan.personal)
        XCTAssertEqual(result["width"] as? Int, 1080)
        XCTAssertEqual(result["video_bitrate"] as? Int, 8_000_000)
        XCTAssertEqual(result["within_limit"] as? Bool, true)
    }
}
