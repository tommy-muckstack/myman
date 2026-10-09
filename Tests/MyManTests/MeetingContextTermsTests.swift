import XCTest
@testable import MyMan

final class MeetingContextTermsTests: XCTestCase {
    func testProperNounsAndEntitiesComeFirst() {
        let text = "Yeah so the Houston rollout slipped. Acme Corp wants the pricing deck before Friday, and pricing is the sticking point for pricing approvals."
        let terms = MeetingContextTerms.salient(in: text, limit: 5)
        XCTAssertFalse(terms.isEmpty)
        let lowered = terms.map { $0.lowercased() }
        XCTAssertTrue(lowered.contains("houston"), "place name should be kept: \(terms)")
        XCTAssertTrue(lowered.contains("acme corp") || lowered.contains("acme"), "organisation should be kept: \(terms)")
        XCTAssertTrue(lowered.contains("pricing"), "a repeated word should be kept: \(terms)")
        XCTAssertFalse(lowered.contains("yeah"))
    }

    func testStopGenericAndCallUIWordsAreDropped() {
        let text = "Okay thanks everyone, mute your mic, the meeting notes summary discussion process steps today tomorrow"
        let terms = MeetingContextTerms.salient(in: text)
        let lowered = Set(terms.map { $0.lowercased() })
        for word in ["okay", "thanks", "mute", "meeting", "notes", "summary", "discussion", "process", "steps", "today", "tomorrow"] {
            XCTAssertFalse(lowered.contains(word), "\(word) should not be a topic term: \(terms)")
        }
    }

    func testAttendeeNamesAreExcluded() {
        let text = "Amy Chen said Amy will send the Amy Chen deck about onboarding onboarding onboarding"
        let terms = MeetingContextTerms.salient(in: text, exclude: ["Amy Chen"])
        let lowered = terms.map { $0.lowercased() }
        XCTAssertFalse(lowered.contains("amy"))
        XCTAssertFalse(lowered.contains("chen"))
        XCTAssertFalse(lowered.contains("amy chen"))
        XCTAssertTrue(lowered.contains("onboarding"))
    }

    func testFrequencyOrdersOrdinaryWordsAndLimitApplies() {
        let text = "budget budget budget timeline timeline roadmap"
        let terms = MeetingContextTerms.salient(in: text, limit: 2)
        XCTAssertEqual(terms.map { $0.lowercased() }, ["budget", "timeline"])
    }

    func testEmptyInput() {
        XCTAssertEqual(MeetingContextTerms.salient(in: ""), [])
        XCTAssertEqual(MeetingContextTerms.salient(in: "budget", limit: 0), [])
    }
}
