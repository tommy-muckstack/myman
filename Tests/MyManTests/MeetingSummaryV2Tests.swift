import XCTest
@testable import MyMan

final class MeetingSummaryV2Tests: XCTestCase {
    func testParagraphsKeepSpeakersAndGapsButJoinRecorderChunks() {
        let raw = MeetingSource.parse("""
        **Alex** [0:10]: I'll I'll

        **Riley** [0:11]: Okay, cool.

        **Alex** [0:13]: Send you the HTML straight away.

        **Riley** [0:17]: I can review the design tomorrow.

        **Riley** [1:20]: This is a separate thought.
        """)
        let turns = MeetingSource.paragraphs(MeetingSource.notesTurns(raw, omitPrivate: false))
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].timestamp, "0:10")
        let action = MeetingEvidence.literalFollowUp(in: turns[0])
        XCTAssertEqual(action?.owner, "Alex")
        XCTAssertTrue(action?.task.contains("HTML") == true)
    }

    func testOwnerQuotesAndUnfinishedClauseFiltering() {
        let meeting = Meeting(id: "quotes-fixture", title: "Design review", startedAt: .now, transcript: """
        **Alex** [1:00]: I believe that customer feedback should drive the product roadmap.

        **Riley** [2:00]: We need to make the onboarding process easier for customers.

        **Alex** [3:00]: I think we should build this because
        """, ownerName: "Alex")
        let quotes = MeetingNoteSections.quotes(meeting: meeting)
        XCTAssertTrue(quotes.contains("— Alex [1:00]"))
        XCTAssertTrue(quotes.contains("— Riley [2:00]"))
        XCTAssertFalse(quotes.contains("build this because"))
    }

    func testScopedNamesCannotRewriteCommonWordsOrProducts() {
        let text = "Talk to Rakner and talk to Ragmit. Look at the motion in the market. Walk with those people to the area."
        let corrected = MeetingPeopleContext.correct(text, names: ["Ragnir", "Looker", "Notion", "Marketo", "WalkMe", "Thomas", "Andrea"])
        XCTAssertEqual(corrected.corrections, ["Rakner → Ragnir", "Ragmit → Ragnir"])
        XCTAssertTrue(corrected.text.hasSuffix("Look at the motion in the market. Walk with those people to the area."))
        XCTAssertEqual(MeetingPeopleContext.correct("Talk to Rakner.", names: []).text, "Talk to Rakner.")
    }

    func testPrivacyPolicyAndNameAuditAreExportedWithoutChangingTranscript() throws {
        let transcript = "**Alex** [1:00]: This is confidential: the launch plan changes tomorrow.\n\n**Riley** [4:00]: I'll talk to Ragnir about the launch plan."
        let original = transcript.replacingOccurrences(of: "Ragnir", with: "Rakner")
        var analysis = MeetingAnalysis(markdown: "Notes")
        analysis.omissionEnabled = true
        let fields = MeetingConversation.metadata(transcript: transcript, summary: "Notes", title: "Launch", owner: "Alex", started: .now, ended: .now, participants: ["Alex", "Riley"], originalTranscript: original, analysisJSON: String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self))
        XCTAssertTrue(fields.contains { $0.contains("[4:00] Rakner → Ragnir") })
        XCTAssertTrue(fields.contains { $0.hasPrefix("omitted:") && $0.contains("1:00") && $0.contains("reason") })
        XCTAssertEqual(MeetingSource.notesTurns(MeetingSource.parse(transcript), omitPrivate: false).count, 2)
    }

    func testUnresolvedTeamReferenceIsSurfacedButPetIsNotATeamMember() {
        let turns = MeetingSource.parse("""
        **Riley** [1:40]: He's been sick for the past three days now.

        **Riley** [1:49]: He's been taking a lot of heat from a customer.

        **Alex** [4:00]: He's a fluffy cat sleeping on the sofa.
        """)
        let result = MeetingTopicNotes.unresolvedReferences(in: turns, participants: [])
        XCTAssertTrue(result.contains("[1:40]"))
        XCTAssertFalse(result.contains("cat"))
    }

    func testRecordingAssociationDoesNotImplyTopicMatch() {
        XCTAssertFalse(ScreenshotIntelligence.offTopicForMeeting(text: "Examplecorp\nExamplecorp\nBoard deck", domains: ["examplecorp.test"]))
        XCTAssertFalse(ScreenshotIntelligence.offTopicForMeeting(text: "Strategy\nStrategy\nBoard deck", domains: ["examplecorp.test"]))
        XCTAssertFalse(ScreenshotIntelligence.offTopicForMeeting(text: "Veltronic\nVeltronic\nBoard deck", domains: []))
    }
}
