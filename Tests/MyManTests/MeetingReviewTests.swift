import XCTest
import GRDB
@testable import MyMan

/// Explicit local review only. Private inputs and generated proposals never
/// enter the repository or touch the live database / Brain exports.
final class MeetingReviewTests: XCTestCase {
    @MainActor func testReviewSuppliedCaptures() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MAN_MEETING_REVIEW_DIR"] else {
            throw XCTSkip("Supply a private review directory containing input.sqlite and review.json")
        }
        struct Review: Decodable {
            let meetingID: String
            let listening: Bool
            let ownerName: String
            let participants: [MeetingParticipant]
            let corrections: [String: String]
            let ignoredTurns: [String]?
        }
        let root = URL(fileURLWithPath: directory)
        let reviews = try JSONDecoder().decode([Review].self, from: Data(contentsOf: root.appendingPathComponent("review.json")))
        let queue = try DatabaseQueue(path: root.appendingPathComponent("input.sqlite").path)
        try Database.migrator.migrate(queue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for review in reviews {
            let fetched = try await queue.read { try Meeting.fetchOne($0, key: review.meetingID) }
            var meeting = try XCTUnwrap(fetched)
            meeting.ownerName = review.ownerName
            meeting.participantsJSON = String(decoding: try encoder.encode(review.participants), as: UTF8.self)
            let proposal = root.appendingPathComponent("\(meeting.id)-proposal.json")
            let transcriptCache = root.appendingPathComponent("\(meeting.id)-transcribed.json")
            if review.listening {
                if FileManager.default.fileExists(atPath: transcriptCache.path) {
                    meeting.transcript = try JSONDecoder().decode(String.self, from: Data(contentsOf: transcriptCache))
                } else {
                    await TranscriptionService.shared.load(kind: .qwen3)
                    guard TranscriptionService.shared.kind == .qwen3 else { throw XCTSkip("Accuracy speech model unavailable") }
                    let result = await MeetingController.buildTranscriptResult(micPath: nil, systemPath: meeting.systemAudioPath)
                    XCTAssertEqual(result.kind, .listening)
                    meeting.transcript = result.transcript
                    try encoder.encode(meeting.transcript).write(to: transcriptCache, options: .atomic)
                }
                meeting.kind = "listening"
                XCTAssertFalse(meeting.transcript.contains("**You**"))
                XCTAssertTrue(MeetingSource.parse(meeting.transcript).allSatisfy { $0.text.count <= 1200 })
            } else {
                let turns = MeetingSource.parse(meeting.transcript)
                let ignored = Set((review.ignoredTurns ?? []).map(MeetingSource.normalized))
                let kept = turns.filter { !MeetingSource.isBackchannel($0.text) && !ignored.contains(MeetingSource.normalized($0.text)) }
                meeting.transcript = kept.map { "**\($0.speaker)** [\($0.timestamp)]: \($0.text)" }.joined(separator: "\n\n")
                XCTAssertEqual(MeetingSource.parse(meeting.transcript).map(\.text), kept.map(\.text))
            }
            let analysis = await GroundedMeetingNotes.generate(meeting, corrections: review.corrections) { stage in
                print("MEETING_REVIEW \(stage)"); fflush(stdout)
            }
            meeting.summary = analysis.markdown
            meeting.analysisJSON = String(decoding: try encoder.encode(analysis), as: UTF8.self)
            try encoder.encode(meeting).write(to: proposal, options: .atomic)
            try Brain.meetingMarkdown(meeting).write(to: root.appendingPathComponent("\(meeting.id)-proposal.md"), atomically: true, encoding: .utf8)
            XCTAssertFalse(meeting.summary.isEmpty)
            if review.listening { XCTAssertTrue(analysis.actions.isEmpty) }
            print("MEETING_REVIEW complete listening=\(review.listening) turns=\(MeetingSource.parse(meeting.transcript).count) facts=\(analysis.facts.count) actions=\(analysis.actions.count)")
        }
    }
}
