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

    // MARK: Slice boundaries

    /// A slice that must be cut before the speech ends should end at the
    /// quietest instant of its tail window — a pause — never mid-word.
    func testLongSliceCutLandsOnTheQuietestFrame() {
        // 3s of "speech" with one silent 0.1s frame planted at 2.5s.
        var samples = [Float](repeating: 0.3, count: 3 * 16000)
        let pause = Int(2.5 * 16000)
        for i in pause ..< pause + 1600 { samples[i] = 0 }
        let cut = MeetingController.quietestCutSample(in: samples, from: 16000)
        XCTAssertEqual(cut, pause)
    }

    /// A tail too short to search keeps the hard cut (returns the full length).
    func testTooShortATailKeepsTheHardCut() {
        let samples = [Float](repeating: 0.3, count: 1000)
        XCTAssertEqual(MeetingController.quietestCutSample(in: samples, from: 500),
                       samples.count)
    }

    // MARK: Meeting naming

    /// A 3-hour focus block that began hours ago must not name a Zoom call
    /// that starts now — only events starting near NOW are plausible.
    func testLongRunningBlockNeverNamesAFreshCall() {
        let now = Date()
        let events = [
            MeetingController.EventTitleCandidate(
                title: "Deep work", start: now.addingTimeInterval(-7200),
                isAllDay: false, hasLink: false, declined: false),
        ]
        XCTAssertNil(MeetingController.bestEventTitle(events, now: now))
    }

    /// The event with the meeting link IS the meeting — it beats a bare
    /// calendar block even when the block started more recently.
    func testLinkedEventOutranksBareBlock() {
        let now = Date()
        let events = [
            MeetingController.EventTitleCandidate(
                title: "Lunch hold", start: now.addingTimeInterval(-60),
                isAllDay: false, hasLink: false, declined: false),
            MeetingController.EventTitleCandidate(
                title: "Design sync", start: now.addingTimeInterval(-300),
                isAllDay: false, hasLink: true, declined: false),
        ]
        XCTAssertEqual(MeetingController.bestEventTitle(events, now: now), "Design sync")
    }

    /// A declined invite never names a recording.
    func testDeclinedEventNeverNamesARecording() {
        let now = Date()
        let events = [
            MeetingController.EventTitleCandidate(
                title: "All-hands (declined)", start: now,
                isAllDay: false, hasLink: true, declined: true),
        ]
        XCTAssertNil(MeetingController.bestEventTitle(events, now: now))
    }

    func testUpcomingEventWithinTenMinutesCanName() {
        let now = Date()
        let events = [
            MeetingController.EventTitleCandidate(
                title: "1:1 Lauren", start: now.addingTimeInterval(300),
                isAllDay: false, hasLink: true, declined: false),
        ]
        XCTAssertEqual(MeetingController.bestEventTitle(events, now: now), "1:1 Lauren")
    }

    // MARK: Formatted transcript rendering

    /// The document view shows turns, not markup — `**Name** [m:ss]:` must
    /// parse into speaker / time / text.
    func testTranscriptTurnsParseCleanly() {
        let transcript = """
        **You** [0:12]: Morning, ready to start?

        **Lauren** [0:19]: Yes — one sec, sharing my screen.
        """
        let turns = MeetingDocumentView.parseTurns(transcript)
        XCTAssertEqual(turns?.count, 2)
        XCTAssertEqual(turns?[0].speaker, "You")
        XCTAssertEqual(turns?[0].time, "0:12")
        XCTAssertEqual(turns?[0].text, "Morning, ready to start?")
        XCTAssertEqual(turns?[1].speaker, "Lauren")
    }

    /// Old two-block transcripts have no turn markers — the raw editor stays
    /// the honest view for them.
    func testUnstructuredTranscriptFallsBackToRawEditor() {
        XCTAssertNil(MeetingDocumentView.parseTurns("You:\nJust a plain block of text."))
    }

    func testEachSpeakerGetsAStableDistinctColor() {
        let turns = [
            MeetingDocumentView.TranscriptTurn(speaker: "You", time: "0:01", text: "a"),
            MeetingDocumentView.TranscriptTurn(speaker: "Lauren", time: "0:05", text: "b"),
            MeetingDocumentView.TranscriptTurn(speaker: "You", time: "0:09", text: "c"),
        ]
        let colors = MeetingDocumentView.speakerColors(for: turns)
        XCTAssertEqual(colors.count, 2)
        XCTAssertNotEqual(colors["You"], colors["Lauren"])
    }

    // MARK: Slide thumbnails

    /// A slide that's mostly letterbox must crop down to its content box.
    func testLetterboxedSlideCropsToContent() throws {
        let width = 200, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height) // black margins
        for y in 30 ..< 70 {
            for x in 50 ..< 150 { pixels[y * width + x] = 220 } // bright content
        }
        let image = try XCTUnwrap(Self.grayImage(pixels: pixels, width: width, height: height))
        let rect = try XCTUnwrap(SlideThumbnailer.contentCropRect(of: image))
        // Content box ±2 coarse pixels of slack.
        XCTAssertEqual(rect.minX, 50, accuracy: 6)
        XCTAssertEqual(rect.minY, 30, accuracy: 6)
        XCTAssertEqual(rect.maxX, 150, accuracy: 6)
        XCTAssertEqual(rect.maxY, 70, accuracy: 6)
    }

    /// A frame that's already all content must be left alone.
    func testFullContentSlideIsNotCropped() throws {
        let width = 128, height = 72
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in pixels.indices { pixels[i] = UInt8((i * 37) % 256) } // busy everywhere
        let image = try XCTUnwrap(Self.grayImage(pixels: pixels, width: width, height: height))
        XCTAssertNil(SlideThumbnailer.contentCropRect(of: image))
    }

    private static func grayImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var data = pixels
        let ctx = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        return ctx?.makeImage()
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

/// The doc-diagnosis fixes: unsupported action items dropped, quiet group
/// participants kept distinct, junk fragments discarded, call-end signals.
final class MeetingDiagnosisFixTests: XCTestCase {
    let transcript = """
    **You** [0:04]: Morning. Let's start with the metrics question.

    **Ran** [4:32]: I'll send the retention doc tonight.

    **Speaker 3** [12:07]: We should think about pricing sometime.
    """

    // MARK: Action-item citations

    func testACitedCommitmentIsSupported() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertTrue(index.supports(owner: "Ran", timestamp: "4:32"))
    }

    func testALeadingZeroTimestampStillMatches() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertTrue(index.supports(owner: "Ran", timestamp: "04:32"))
    }

    func testAFabricatedTimestampIsRejected() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertFalse(index.supports(owner: "Ran", timestamp: "39:33"))
    }

    func testAnOwnerWhoNeverSpokeIsRejected() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertFalse(index.supports(owner: "Chris", timestamp: "4:32"))
    }

    func testAnEmptyOwnerNeedsOnlyARealTimestamp() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertTrue(index.supports(owner: "", timestamp: "0:04"))
    }

    func testTheOldTwoBlockFormatSkipsValidation() {
        let index = TranscriptIndex(transcript: "You:\nHello there.\n\nSpeaker 2:\nHi.")
        XCTAssertTrue(index.supports(owner: "Anyone", timestamp: "9:99"))
    }

    // MARK: Group-call speaker folding

    /// Four-person call: a participant holding 9% of the dominant voice is a
    /// quiet human, not an artefact — they must stay their own speaker.
    func testAQuietGroupParticipantIsNotFoldedAway() {
        let segments: [(speaker: String, start: Double, end: Double)] = [
            ("A", 0, 600), ("B", 600, 800), ("C", 800, 900), ("D", 900, 950)
        ]
        let collapsed = MeetingController.collapsePhantomSpeakers(in: segments)
        XCTAssertEqual(Set(collapsed.map(\.speaker)), ["A", "B", "C", "D"])
    }

    /// A sub-8s blip is still echo, even in a group call.
    func testASubEightSecondBlipStillFoldsInAGroupCall() {
        let segments: [(speaker: String, start: Double, end: Double)] = [
            ("A", 0, 600), ("B", 600, 800), ("C", 800, 900), ("D", 900, 904)
        ]
        let collapsed = MeetingController.collapsePhantomSpeakers(in: segments)
        XCTAssertEqual(Set(collapsed.map(\.speaker)), ["A", "B", "C"])
    }

    /// The original 1:1 case is unchanged: a low-share second voice on the
    /// remote stream is echo and folds into the dominant voice.
    func testAOneOnOneEchoVoiceStillFolds() {
        let segments: [(speaker: String, start: Double, end: Double)] = [
            ("A", 0, 600), ("B", 600, 620)
        ]
        let collapsed = MeetingController.collapsePhantomSpeakers(in: segments)
        XCTAssertEqual(Set(collapsed.map(\.speaker)), ["A"])
    }

    // MARK: Noise fragments

    private func meeting(seconds: Double, words: Int) -> Meeting {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return Meeting(id: "m", title: "t", startedAt: start,
                       endedAt: start.addingTimeInterval(seconds),
                       micAudioPath: nil, systemAudioPath: nil,
                       transcript: Array(repeating: "word", count: words)
                           .joined(separator: " "))
    }

    func testAShortSparseRecordingIsNoise() {
        XCTAssertTrue(MeetingController.isNoiseFragment(meeting(seconds: 28, words: 28)))
    }

    func testAShortButDenseRecordingIsKept() {
        XCTAssertFalse(MeetingController.isNoiseFragment(meeting(seconds: 50, words: 140)))
    }

    /// A long meeting whose ASR failed must NEVER be deleted — that is a
    /// real meeting with a broken transcript, not noise.
    func testALongRecordingWithFewWordsIsKept() {
        XCTAssertFalse(MeetingController.isNoiseFragment(meeting(seconds: 3400, words: 40)))
    }

    // MARK: Call-end signals

    func testBrowserHelperBundlesCountAsCallApps() {
        XCTAssertTrue(MeetingDetector.isCallBundle("com.google.Chrome"))
        XCTAssertTrue(MeetingDetector.isCallBundle("com.google.Chrome.helper"))
        XCTAssertTrue(MeetingDetector.isCallBundle("com.apple.WebKit.WebContent"))
        XCTAssertTrue(MeetingDetector.isCallBundle("us.zoom.xos"))
        XCTAssertFalse(MeetingDetector.isCallBundle("com.apple.Music"))
    }

    func testMeetingWindowTitlesAreRecognised() {
        XCTAssertTrue(MeetingDetector.isMeetingWindowTitle("Zoom Meeting"))
        XCTAssertTrue(MeetingDetector.isMeetingWindowTitle("Meet – abc-defg-hij"))
        XCTAssertTrue(MeetingDetector.isMeetingWindowTitle("Meet - weekly sync"))
        XCTAssertFalse(MeetingDetector.isMeetingWindowTitle("Meet"))
        XCTAssertFalse(MeetingDetector.isMeetingWindowTitle("Meetings that could have been emails"))
        XCTAssertFalse(MeetingDetector.isMeetingWindowTitle("Inbox — Gmail"))
    }
}
