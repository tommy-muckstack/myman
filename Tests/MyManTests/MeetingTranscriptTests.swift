import XCTest
@testable import MyMan

/// Regression cases for the meeting-transcript defects found by diffing one
/// meeting against two other recorders: shredded local audio, a phantom third
/// speaker in a 1:1, a raw email address used as a speaker label, and a name
/// guessed from a drifting calendar title being stamped on someone's words.
final class MeetingTranscriptTests: XCTestCase {

    // MARK: Fragment merging

    /// "You'd have a PM." / "PM" / "Designer." / "Six." — four transcript
    /// lines that were one sentence.
    func testConsecutiveFragmentsFromOneSpeakerBecomeOneUtterance() {
        let turns = [
            MeetingTurn(start: 486, end: 488, speaker: "You", text: "You'd have a PM."),
            MeetingTurn(start: 489, end: 490, speaker: "You", text: "A designer."),
            MeetingTurn(start: 493, end: 497, speaker: "You", text: "Four to six engineers."),
        ]
        let merged = MeetingController.mergeConsecutive(turns)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "You'd have a PM. A designer. Four to six engineers.")
        XCTAssertEqual(merged[0].start, 486)
        XCTAssertEqual(merged[0].end, 497)
    }

    func testDifferentSpeakersAreNeverMerged() {
        let turns = [
            MeetingTurn(start: 10, end: 12, speaker: "You", text: "How about you?"),
            MeetingTurn(start: 13, end: 20, speaker: "Lauren", text: "Good, thanks."),
        ]
        XCTAssertEqual(MeetingController.mergeConsecutive(turns).count, 2)
    }

    func testALongPauseStillStartsANewUtterance() {
        let turns = [
            MeetingTurn(start: 10, end: 12, speaker: "You", text: "One thing."),
            MeetingTurn(start: 60, end: 64, speaker: "You", text: "A separate thought."),
        ]
        XCTAssertEqual(MeetingController.mergeConsecutive(turns).count, 2)
    }

    /// Merging happens at the audio level too, so the recognizer sees the
    /// whole phrase instead of a 1-second clip with no context.
    func testShortPausesAreGluedBeforeTranscription() {
        let merged = MeetingController.mergeSegments([(1, 2), (3.5, 4), (10, 12)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 1)
        XCTAssertEqual(merged[0].end, 4)
        XCTAssertEqual(merged[1].start, 10)
    }

    // MARK: Speaker identity

    func testAnEmailAddressNeverBecomesASpeakerLabel() {
        XCTAssertEqual(MeetingController.firstName(fromAttendee: "michael.bird@amplitude.com"),
                       "Michael")
        XCTAssertEqual(MeetingController.firstName(fromAttendee: "Lauren Comer"), "Lauren")
        XCTAssertNil(MeetingController.firstName(fromAttendee: "x@y.com"))
    }

    func testAttendeeNamesAreTrustedAndTitleGuessesAreNot() {
        let fromList = MeetingController.speakerCandidates(
            eventTitle: "Tommy / Lauren Weekly", attendees: ["Lauren Comer"])
        XCTAssertEqual(fromList.names, ["Lauren"])
        XCTAssertTrue(fromList.fromAttendees)

        let fromTitle = MeetingController.speakerCandidates(
            eventTitle: "\(NSFullUserName()) Lauren Weekly", attendees: [])
        XCTAssertFalse(fromTitle.fromAttendees)
    }

    /// The misfiling case: a recording that ran across two calendar slots
    /// picked up the wrong title, so the "attendee" was never in the room.
    /// A guess must leave the label positional.
    func testAGuessedNameIsNotStampedOnRemoteTurns() {
        let turns = [
            MeetingTurn(start: 0, end: 4, speaker: "You", text: "Hello."),
            MeetingTurn(start: 5, end: 9, speaker: MeetingController.remoteLabel, text: "Hi."),
        ]
        let guessed = SpeakerCandidates(names: ["Lauren"], fromAttendees: false)
        XCTAssertEqual(MeetingController.nameSpeakers(in: turns, candidates: guessed)[1].speaker,
                       MeetingController.remoteLabel)

        let known = SpeakerCandidates(names: ["Lauren"], fromAttendees: true)
        XCTAssertEqual(MeetingController.nameSpeakers(in: turns, candidates: known)[1].speaker,
                       "Lauren")
    }

    func testNoLabelIsEverThemOrOthers() {
        XCTAssertFalse(["Them", "Others"].contains(MeetingController.remoteLabel))
    }

    /// A few seconds of backchannel split off as its own diarized voice
    /// invented a third participant in a two-person call.
    func testBackchannelDoesNotBecomeAThirdParticipant() {
        let segments: [(speaker: String, start: Double, end: Double)] = [
            ("A", 0, 120),
            ("B", 121, 123),   // "mm-hmm"
            ("A", 124, 300),
        ]
        let collapsed = MeetingController.collapsePhantomSpeakers(in: segments)
        XCTAssertEqual(Set(collapsed.map(\.speaker)), ["A"])
    }

    func testTwoRealVoicesAreBothKept() {
        let segments: [(speaker: String, start: Double, end: Double)] = [
            ("A", 0, 120),
            ("B", 121, 240),
        ]
        let collapsed = MeetingController.collapsePhantomSpeakers(in: segments)
        XCTAssertEqual(Set(collapsed.map(\.speaker)), ["A", "B"])
    }

    // MARK: Frontmatter

    func testParticipantsAreReadBackOutOfTheTranscript() {
        let transcript = """
        **You** [0:04]: Morning.

        **Lauren Comer** [0:09]: Morning.

        **You** [0:14]: Shall we start?
        """
        XCTAssertEqual(Brain.speakers(in: transcript), ["You", "Lauren Comer"])
    }

    func testParticipantsAlsoWorkOnTheOlderTwoBlockFormat() {
        let transcript = "You:\nSome things were said.\n\nSpeaker 2:\nAnd some more."
        XCTAssertEqual(Brain.speakers(in: transcript), ["You", "Speaker 2"])
    }

    // MARK: Deadlines

    func testSpokenDeadlinesResolveAgainstTheMeetingDate() {
        // Monday 2026-08-10, the meeting in the spec.
        let monday = ISO8601DateFormatter().date(from: "2026-08-10T18:00:00Z")!
        XCTAssertEqual(DueDate.resolve("Wednesday end of day", from: monday), "2026-08-12")
        XCTAssertEqual(DueDate.resolve("this afternoon", from: monday), "2026-08-10")
        XCTAssertEqual(DueDate.resolve("tomorrow", from: monday), "2026-08-11")
        XCTAssertNil(DueDate.resolve("soon", from: monday))
    }

    func testTheMeetingsOwnWeekdayResolvesToThatSameDay() {
        let wednesday = ISO8601DateFormatter().date(from: "2026-08-12T18:00:00Z")!
        XCTAssertEqual(DueDate.resolve("by Wednesday", from: wednesday), "2026-08-12")
    }
}

/// The summary pass is told not to write action items; the extractor owns
/// that section. This is the belt to that prompt's braces.
final class MeetingSummaryShapeTests: XCTestCase {
    func testAModelProducedActionItemsSectionIsRemoved() {
        let markdown = """
        ## Summary

        They talked.

        ## Action items

        * Explore AI-driven Solutions
        * Review and Adjust Testing Strategies
        """
        let stripped = MeetingSummarizer.stripActionItems(markdown)
        XCTAssertFalse(stripped.contains("Explore AI-driven Solutions"))
        XCTAssertTrue(stripped.contains("They talked."))
    }

    func testLaterSectionsSurviveTheStrip() {
        let markdown = "## Action items\n\n* A thing\n\n## Key points\n\n* A real point"
        let stripped = MeetingSummarizer.stripActionItems(markdown)
        XCTAssertTrue(stripped.contains("A real point"))
        XCTAssertFalse(stripped.contains("A thing"))
    }
}
