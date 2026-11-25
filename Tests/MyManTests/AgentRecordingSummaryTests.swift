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
}
