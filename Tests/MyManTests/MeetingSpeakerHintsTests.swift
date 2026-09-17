import XCTest
@testable import MyMan

final class MeetingSpeakerHintsTests: XCTestCase {
    func testLiteralNamesAndConservativeContext() {
        for name in ["Casey", "Ana María", "Jean-Luc", "O’Neil", "A+B"] {
            let turns = [
                MeetingTurn(start: 0, end: 1, speaker: "Speaker 2", text: "Hello. I’m \(name)."),
                MeetingTurn(start: 2, end: 3, speaker: "You", text: "Thanks! Hey \(name), could you explain?"),
                MeetingTurn(start: 4, end: 5, speaker: "Speaker 2", text: "Yes.")
            ]
            XCTAssertEqual(MeetingSpeakerHints.votes(in: turns, names: [name, name])["Speaker 2"]?[name], 4)
        }
        for text in ["Caseyson, can you explain?", "I mentioned Casey what he said.", "That is Casey.", "they Casey, can you explain?"] {
            let turns = [MeetingTurn(start: 0, end: 1, speaker: "You", text: text),
                         MeetingTurn(start: 2, end: 3, speaker: "Speaker 2", text: "Yes.")]
            XCTAssertTrue(MeetingSpeakerHints.votes(in: turns, names: ["Casey"]).isEmpty, text)
        }
    }

    func testNextDistinctVoiceMustBeTimelyAndUnambiguous() {
        let question = MeetingTurn(start: 0, end: 1, speaker: "You", text: "Casey, can you explain?")
        let continuation = MeetingTurn(start: 2, end: 3, speaker: "You", text: "Please go ahead.")
        for next in [MeetingTurn(start: 0, end: 3, speaker: "Speaker 2", text: "Overlapping."),
                     MeetingTurn(start: 17, end: 18, speaker: "Speaker 2", text: "Too late."),
                     MeetingTurn(start: 4, end: 5, speaker: "Speaker unclear", text: "Mixed voices.")] {
            XCTAssertTrue(MeetingSpeakerHints.votes(in: [question, continuation, next], names: ["Casey"]).isEmpty)
        }
        let response = MeetingTurn(start: 4, end: 5, speaker: "Speaker 2", text: "Yes.")
        XCTAssertEqual(MeetingSpeakerHints.votes(in: [question, continuation, response], names: ["Casey"])["Speaker 2"]?["Casey"], 1)
    }

    @MainActor func testLargeRefreshYieldsAndPreservesEditsAndStop() async throws {
        let transcript = LiveMeetingTranscript()
        let turns = (0..<2400).map { index in
            MeetingTurn(start: Double(index * 2), end: Double(index * 2 + 1),
                        speaker: index.isMultiple(of: 2) ? "You" : "Speaker 2", text: "Original sentence \(index).")
        }
        let start = ContinuousClock.now
        transcript.append(turns, ownerName: "Alex", candidates: .none)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500), "Rendering must yield the UI thread")
        XCTAssertTrue(transcript.rows.isEmpty, "Large histories must render asynchronously")
        try await waitUntil { transcript.rows.count == turns.count }
        let row = transcript.rows[1]
        transcript.edit(rowID: row.id, text: "My corrected sentence.", speakerName: "Morgan")
        transcript.updateCallParticipants(["Casey", "Jamie"], candidates: SpeakerCandidates(names: ["Casey", "Jamie"], fromAttendees: false))
        try await waitUntil { transcript.rows.contains { $0.text == "My corrected sentence." } }
        XCTAssertEqual(transcript.rows.first { $0.id == row.id }?.speaker, "Morgan")
        XCTAssertEqual(transcript.corrections.first?.text, "My corrected sentence.")
        transcript.updateCandidates(SpeakerCandidates(names: ["Taylor"], fromAttendees: false))
        transcript.stop()
        transcript.append([MeetingTurn(start: 0, end: 1, speaker: "You", text: "A new meeting.")], ownerName: "Alex", candidates: .none)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transcript.rows.map(\.text), ["A new meeting."])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Background transcript refresh did not finish")
    }

    func testLongMeetingEvidenceRemainsResponsive() {
        let names = (0..<20).map { "Participant \($0)" }
        let turns = (0..<2400).map { index in
            MeetingTurn(start: Double(index * 2), end: Double(index * 2 + 1),
                        speaker: index.isMultiple(of: 2) ? "You" : "Speaker 2",
                        text: index.isMultiple(of: 2) ? "Participant 3, what do you think about the next draft?" : "I think we should review the proposal together before we decide.")
        }
        let start = ContinuousClock.now
        let votes = MeetingSpeakerHints.votes(in: turns, names: names)
        let elapsed = start.duration(to: .now)
        print("SPEAKER_HINTS_80_MINUTES \(elapsed)")
        XCTAssertEqual(votes["Speaker 2"]?["Participant 3"], 1200)
        XCTAssertLessThan(elapsed, .seconds(1), "Speaker matching must not stall a long meeting")
    }
}
