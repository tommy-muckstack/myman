import XCTest
@testable import MyMan

final class MeetingAcceptanceTests: XCTestCase {
    func testVocabularyDoesNotTurnCommonWordsIntoHotwords() {
        let source = "We look at the map and study motion. Please walk to the market. This area is open to those visitors. We heard about Shop Monkey."
        let terms = MeetingVocabulary.commonTerms + ["Andrea", "Thomas", "Shopmonkey"]
        let result = MeetingVocabulary.correct(source, terms: terms, aliases: ["Shop Monkey": "Shopmonkey"])
        XCTAssertEqual(result.text, source.replacingOccurrences(of: "Shop Monkey", with: "Shopmonkey"))
        XCTAssertEqual(MeetingVocabulary.correct("We use Looker, Notion and Shopify.", terms: terms).text, "We use Looker, Notion and Shopify.")
    }

    func testHotwordFrequencyFlagsWithoutChangingText() {
        let text = "Looker Looker Looker " + Array(repeating: "ordinary words", count: 100).joined(separator: " ")
        XCTAssertEqual(MeetingVocabulary.flaggedTokens(in: text, context: "Alex <> Morgan", terms: ["Looker"]), ["Looker"])
        XCTAssertEqual(MeetingVocabulary.flaggedTokens(in: text, context: "Looker onboarding", terms: ["Looker"]), [])
    }

    func testExplicitPairCollapsesRemoteLabelsAndDropsWarmup() {
        var meeting = Meeting(id: "test", title: "CI: Google Meet: Alexander (Alex) Rivera <> Morgan Chen", startedAt: Date(timeIntervalSince1970: 0), transcript: "")
        meeting.ownerName = "Alex Rivera"
        let text = "**You** [1:13]: Alright.\n\n**Speaker 3** [4:48]: Hi, Alex.\n\n**You** [4:54]: Hello there.\n\n**Speaker unclear** [5:01]: Yes.\n\n**Speaker 2** [5:10]: I think staff adoption is important."
        meeting.transcript = MeetingConversation.finish(text, meeting: meeting)
        XCTAssertFalse(meeting.transcript.contains("Alright"))
        XCTAssertEqual(Set(MeetingSource.parse(meeting.transcript).map(\.speaker)), ["Alex Rivera", "Morgan Chen"])
        XCTAssertNil(MeetingConversation.explicitPair(title: "Project review with Morgan", owner: meeting.ownerName))
        let pending = MeetingConversation.metadata(transcript: "", summary: "", title: meeting.title, owner: meeting.ownerName, started: meeting.startedAt, ended: nil, participants: [])
        XCTAssertTrue(pending.contains("status: transcribing"))
        let complete = MeetingConversation.metadata(transcript: meeting.transcript, summary: "Notes", title: meeting.title, owner: meeting.ownerName, started: meeting.startedAt, ended: Date(), participants: [])
        XCTAssertTrue(complete.contains("status: complete"))
        XCTAssertTrue(complete.contains("call_start_offset_seconds: 288"))
        XCTAssertTrue(complete.contains("call_started_at: 1970-01-01T00:04:48Z"))
    }

    func testNotesContainVerbatimQuotesAndExplicitEmptyNextSteps() {
        var meeting = Meeting(id: "test", title: "Call", startedAt: Date(), transcript: "**Morgan Chen** [4:48]: I think staff adoption is important for success.")
        meeting.ownerName = "Alex Rivera"
        let output = GroundedMeetingNotes.render(facts: [], actions: [], sources: [:], meeting: meeting, privateOmitted: false)
        XCTAssertTrue(output.contains("## Quotes"))
        XCTAssertTrue(output.contains("“I think staff adoption is important for success.”"))
        XCTAssertTrue(output.contains("## Next steps\n\nNone agreed."))
    }
}
