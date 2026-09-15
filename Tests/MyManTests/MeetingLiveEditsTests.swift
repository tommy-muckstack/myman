import AVFoundation
import GRDB
import XCTest
@testable import MyMan

final class MeetingLiveEditsTests: XCTestCase {
    func testAddressedQuestionIsOnlyASuggestionUntilEvidenceAccumulates() {
        let turns = [
            MeetingTurn(start: 0, end: 4, speaker: "You", text: "Tommy what do you think?"),
            MeetingTurn(start: 5, end: 9, speaker: "Speaker 2", text: "I think Friday works.")
        ]
        let candidates = SpeakerCandidates(names: ["Tommy", "Jamie"], fromAttendees: true)
        XCTAssertEqual(MeetingSpeakerHints.suggestions(in: turns, names: candidates.names)["Speaker 2"], "Tommy")
        XCTAssertEqual(MeetingController.nameSpeakers(in: turns, candidates: candidates)[1].speaker, "Speaker 2")
        let repeated = turns + [
            MeetingTurn(start: 10, end: 14, speaker: "You", text: "Tommy, can you send it?"),
            MeetingTurn(start: 15, end: 19, speaker: "Speaker 2", text: "I will send the draft.")
        ]
        XCTAssertEqual(MeetingController.nameSpeakers(in: repeated, candidates: candidates)[1].speaker, "Tommy")
        let mention = [MeetingTurn(start: 0, end: 4, speaker: "You", text: "I asked Tommy what he thinks."), turns[1]]
        XCTAssertTrue(MeetingSpeakerHints.suggestions(in: mention, names: candidates.names).isEmpty)
        let overlap = [turns[0], MeetingTurn(start: 3, end: 7, speaker: "Speaker 2", text: "Another voice interrupts.")]
        XCTAssertTrue(MeetingSpeakerHints.suggestions(in: overlap, names: candidates.names).isEmpty)
    }

    @MainActor func testManualEditsOverrideGuessesAndPersistOnTheMeeting() throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: "edited", title: "Review", startedAt: Date(), transcript: "")
        try db.write { try meeting.insert($0) }
        let controller = MeetingController(recording: meeting, titleDatabase: db)
        // Keep this deterministic test out of the user's vocabulary store.
        controller.liveTranscript.onTextCorrected = { _ in }
        controller.liveTranscript.append([
            MeetingTurn(start: 0, end: 5, speaker: "Speaker 2", text: "A rough transcript."),
            MeetingTurn(start: 8, end: 12, speaker: "Speaker 2", text: "The next sentence.")
        ], ownerName: "Alex", candidates: SpeakerCandidates(names: ["Jamie"], fromAttendees: true))
        let id = try XCTUnwrap(controller.liveTranscript.rows.first?.id)
        controller.liveTranscript.edit(rowID: id, text: "A corrected transcript.", speakerName: "Morgan")
        XCTAssertEqual(controller.liveTranscript.rows.map(\.speaker), ["Morgan", "Morgan"])
        XCTAssertEqual(controller.liveTranscript.rows.first?.text, "A corrected transcript.")
        let saved = try XCTUnwrap(db.read { try Meeting.fetchOne($0, key: "edited") })
        XCTAssertEqual(saved.liveCorrections.count, 2)
        XCTAssertEqual(saved.liveCorrections.first?.text, "A corrected transcript.")
        XCTAssertFalse(controller.liveEditSaveFailed)
    }

    func testFinalCorrectionRetainsSpeechOnBothEdgesAndOtherChannel() async {
        let source = [MeetingTurn(start: 0, end: 20, speaker: "You", text: "A longer machine transcript."),
                      MeetingTurn(start: 5, end: 10, speaker: "Speaker 2", text: "Remote speech stays.")]
        let edit = LiveTranscriptCorrection(id: "edit", sourceSpeaker: "You", start: 5, end: 10,
                                            text: "The human correction.", speakerName: "Alex")
        let result = await MeetingLiveEdits.apply([edit], to: source) { edge in
            [MeetingTurn(start: edge.start, end: edge.end, speaker: edge.speaker,
                         text: edge.start == 0 ? "Before the edit." : "After the edit.")]
        }
        XCTAssertEqual(Set(result.map(\.text)), Set(["Before the edit.", "After the edit.", "The human correction.", "Remote speech stays."]))
        XCTAssertEqual(result.first(where: { $0.text == "The human correction." })?.speaker, "Alex")
    }

    func testVoiceProfilesOnlyRememberConfirmedNamesAndCanBeForgotten() throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        var embedding = Array(repeating: Float(0), count: 256)
        embedding[0] = 1
        XCTAssertThrowsError(try VoiceProfiles.remember(name: "Speaker 2", embedding: embedding, database: db))
        let first = try VoiceProfiles.remember(name: "Jamie Lee", embedding: embedding, database: db)
        let second = try VoiceProfiles.remember(name: "Jamie Lee", embedding: embedding, database: db)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try VoiceProfiles.all(database: db).count, 1)
        try VoiceProfiles.forget(name: "Jamie Lee", database: db)
        XCTAssertTrue(try VoiceProfiles.all(database: db).isEmpty)
    }

    /// Opt-in smoke test uses generated speech, never a private meeting.
    func testRealLiveDecoderWithSyntheticSpeech() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYMAN_LIVE_SYNTHETIC_AUDIO"] else {
            throw XCTSkip("Set MYMAN_LIVE_SYNTHETIC_AUDIO to generated speech to exercise the cached on-device model")
        }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: buffer)
        XCTAssertEqual(source.processingFormat.sampleRate, 16000)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url))
        writer.append(samples)
        defer { _ = writer.close() }
        let reader = LiveMeetingTranscriptReader(micURL: url, systemURL: nil, singleRemote: false)
        try await reader.prepare()
        let turns = try await reader.next()
        XCTAssertFalse(turns.isEmpty)
        XCTAssertTrue(turns.allSatisfy { $0.speaker == "You" })
        XCTAssertTrue(turns.map(\.text).joined(separator: " ").lowercased().contains("proposal"))
        print("Live synthetic transcript: \(turns.map(\.text).joined(separator: " "))")
        let profiles = try DatabaseQueue()
        try Database.migrator.migrate(profiles)
        let enrollment = LiveMeetingTranscriptReader(micURL: nil, systemURL: url, singleRemote: false, profileDatabase: profiles)
        try await enrollment.rememberVoice(name: "Synthetic Narrator", start: 0, end: min(8, Double(samples.count) / 16000))
        let savedProfiles = try VoiceProfiles.all(database: profiles)
        XCTAssertEqual(savedProfiles.first?.name, "Synthetic Narrator")
        XCTAssertEqual(savedProfiles.first?.embedding.count, 256)
        let nextMeeting = LiveMeetingTranscriptReader(micURL: nil, systemURL: url, singleRemote: false, profileDatabase: profiles)
        try await nextMeeting.prepare()
        let recognized = try await nextMeeting.next()
        XCTAssertFalse(recognized.isEmpty)
        XCTAssertTrue(recognized.contains { $0.speaker == "Synthetic Narrator" }, "The next session should recognize an explicitly enrolled voice")
    }
}
