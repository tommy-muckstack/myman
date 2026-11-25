import XCTest
@testable import MyMan

final class AgentRecordingSummaryTests: XCTestCase {
    func testFramesEveryTenSecondsFromZero() {
        XCTAssertEqual(AgentRecordingSummary.frameTimes(duration: 25), [0, 10, 20])
    }
    func testFramesAreCappedSoASummaryStaysSmall() {
        XCTAssertEqual(AgentRecordingSummary.frameTimes(duration: 10_000).count, AgentRecordingSummary.maximumFrames)
    }
    func testNoFramesForEmptyOrZeroLength() {
        XCTAssertEqual(AgentRecordingSummary.frameTimes(duration: 0), [])
        XCTAssertEqual(AgentRecordingSummary.frameTimes(duration: 5, every: 0), [])
    }
    @MainActor func testFrameErrorsCarryANextStep() {
        do {
            _ = try AgentVideo.sampleTimes([99], count: 1, duration: 10)
            XCTFail("expected an error")
        } catch let error as AgentError {
            XCTAssertEqual(error.code, "INVALID_ARGUMENTS")
            XCTAssertNotNil(error.details["next_step"] as? String)
        } catch { XCTFail("wrong error \(error)") }
    }
    func testRecommendedCountIsCapped() {
        XCTAssertEqual(AgentRecordingSummary.frameTimes(duration: 600, every: 100, maximum: AgentRecordingSummary.maximumRecommended).count, 6)
    }
}
