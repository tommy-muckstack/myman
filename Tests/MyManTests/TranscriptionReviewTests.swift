import XCTest
import NaturalLanguage
@testable import MyMan

/// Regression cases from the 2026-09-15 transcription review: ordering,
/// speaker boundaries, unreadable notes, vocabulary, and participants.
final class TranscriptionReviewTests: XCTestCase {
    func testAQuietRealParticipantIsNotFoldedIntoTheLeadVoice() {
        func segments(lead: Double, other: Double) -> [(speaker: String, start: Double, end: Double)] {
            [("A", 0, lead), ("B", lead + 1, lead + 1 + other)]
        }
        // An interviewer asking a few questions across a 20-minute call.
        let colleague = MeetingController.collapsePhantomSpeakers(in: segments(lead: 600, other: 45))
        XCTAssertEqual(Set(colleague.map(\.speaker)), ["A", "B"])
        // Echo and backchannel: a few seconds, folded.
        let echo = MeetingController.collapsePhantomSpeakers(in: segments(lead: 600, other: 5))
        XCTAssertEqual(Set(echo.map(\.speaker)), ["A"])
        // A sliver under both the share and length floors, folded.
        let sliver = MeetingController.collapsePhantomSpeakers(in: segments(lead: 600, other: 20))
        XCTAssertEqual(Set(sliver.map(\.speaker)), ["A"])
    }

    func testFallbackChunksAreDatedToTheirSpeechNotTheChunkStart() {
        var samples = [Float](repeating: 0, count: 16000 * 10)
        for index in (16000 * 4)..<(16000 * 6) { samples[index] = sin(Float(index) * 0.05) * 0.3 }
        let bounds = try! XCTUnwrap(MeetingController.audibleBounds(samples))
        XCTAssertEqual(bounds.start, 4, accuracy: 0.15)
        XCTAssertEqual(bounds.end, 6, accuracy: 0.15)
        XCTAssertNil(MeetingController.audibleBounds([Float](repeating: 0, count: 16000)))
    }

    func testUnreadablePassagesNeverBecomeNotes() {
        XCTAssertFalse(MeetingEvidence.legible("agnıs is the main common Turkish term we use for that"))
        XCTAssertFalse(MeetingEvidence.legible("Это совсем другой язык здесь"))
        XCTAssertTrue(MeetingEvidence.legible("Michelle uses Amplitude data in a broader anomaly monitoring workflow."))
        XCTAssertTrue(MeetingEvidence.legible("Send the deck"))
        let sources = [1: MeetingSourceTurn(id: 1, speaker: "Morgan", timestamp: "3:10",
                                            text: "So agnıs is the main common Turkish term we use for that in our workspace every day.")]
        XCTAssertNil(MeetingEvidence.fact(MeetingFact(sourceID: 1, text: "Morgan explained agnıs as the main term.",
                                                      quote: "agnıs is the main common Turkish term", importance: 3), sources: sources))
    }

    func testMeetingContextRestoresProductAndCompanySpellings() {
        let terms = MeetingController.vocabularyTerms(
            candidates: SpeakerCandidates(names: ["Michelle Shih"], fromAttendees: true),
            title: "MCP User Research - Michelle Shih and Carmen DeCouto | Credit Genie")
        XCTAssertTrue(terms.contains("Amplitude")); XCTAssertTrue(terms.contains("Jupyter"))
        XCTAssertTrue(terms.contains("Carmen")); XCTAssertTrue(terms.contains("Genie"))
        XCTAssertFalse(terms.contains("User")); XCTAssertFalse(terms.contains("Research"))
        XCTAssertEqual(DictationCleanup.applyVocabulary("We also call Amplitune C P.", terms: terms), "We also call Amplitude C P.")
        XCTAssertEqual(DictationCleanup.applyVocabulary("the Jupiter container", terms: terms), "the Jupyter container")
        // Ordinary words are never swapped for a product.
        XCTAssertEqual(DictationCleanup.applyVocabulary("switch to clock", terms: terms), "switch to clock")
        XCTAssertEqual(MeetingVocabulary.properNouns(in: "Weekly sync"), [])
    }

    func testTimelineScaleAndLagAreOnlyAppliedWhereEarned() {
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 1230, wallSeconds: 1231), 1)
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 1300, wallSeconds: 1231), 1231.0 / 1300.0, accuracy: 0.0001)
    }

    func testBrainExportSeparatesObservedSpeakersFromCalendarInvitees() {
        var meeting = Meeting(id: "m", title: "Review", startedAt: Date(timeIntervalSince1970: 1_788_523_200),
                              transcript: "**You** [0:00]: Hi.\n\n**Morgan Taylor** [0:05]: Hello.", summary: "")
        meeting.ownerName = "Alex Rivera"
        let people = [MeetingParticipant(name: "Alex Rivera", email: "alex@example.com", isOwner: true),
                      MeetingParticipant(name: "Morgan Taylor", email: "morgan@example.com"),
                      MeetingParticipant(name: "Casey Lee", email: "casey@example.com")]
        meeting.participantsJSON = String(decoding: try! JSONEncoder().encode(people), as: UTF8.self)
        let markdown = Brain.meetingMarkdown(meeting)
        let participants = markdown.components(separatedBy: "participants:\n")[1].components(separatedBy: "calendar_invitees:\n")[0]
        XCTAssertTrue(participants.contains("Morgan Taylor <morgan@example.com>"))
        XCTAssertFalse(participants.contains("Casey Lee"), "an invitee who never spoke is not a participant")
        let invitees = markdown.components(separatedBy: "calendar_invitees:\n")[1].components(separatedBy: "---")[0]
        XCTAssertTrue(invitees.contains("Casey Lee")); XCTAssertTrue(invitees.contains("Morgan Taylor"))
        XCTAssertFalse(invitees.contains("Alex Rivera"))
    }
}
