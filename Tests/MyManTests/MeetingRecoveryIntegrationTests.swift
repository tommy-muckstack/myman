import Foundation
import GRDB
import XCTest
@testable import MyMan

/// Explicit, local-only recovery against a copied database. Never changes the
/// user's library or prints conversation content in test logs.
final class MeetingRecoveryIntegrationTests: XCTestCase {
    @MainActor func testAcceptanceNotesAndExport() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_ACCEPTANCE_NOTES_FOLDER"] else {
            throw XCTSkip("Opt-in recovered notes/export check")
        }
        let root = URL(fileURLWithPath: folder)
        var meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: root.appendingPathComponent("acceptance-meeting.json")))
        let analysis = await MeetingNotesService.generateBounded(meeting)
        meeting.summary = analysis.markdown
        meeting.analysisJSON = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
        let markdown = Brain.meetingMarkdown(meeting)
        try markdown.write(to: root.appendingPathComponent("acceptance-meeting.md"), atomically: true, encoding: .utf8)
        try meeting.summary.write(to: root.appendingPathComponent("acceptance-notes.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(meeting).write(to: root.appendingPathComponent("acceptance-meeting.json"), options: .atomic)
        XCTAssertTrue(markdown.contains("status: complete"))
        XCTAssertTrue(markdown.contains("call_started_at:"))
        XCTAssertTrue(markdown.contains("## Quotes"))
        XCTAssertTrue(markdown.contains("## Next steps"))
        let pair = try XCTUnwrap(MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName))
        XCTAssertEqual(Set(MeetingSource.parse(meeting.transcript).map(\.speaker)), [pair.owner, pair.remote])
        let forbiddenJSON = ProcessInfo.processInfo.environment["MYMAN_ACCEPTANCE_FORBIDDEN"] ?? "[]"
        let forbidden = try JSONDecoder().decode([String].self, from: Data(forbiddenJSON.utf8))
        for bad in forbidden {
            XCTAssertFalse(meeting.transcript.contains(bad), "Unexpected substitution: \(bad)")
        }
    }
    func testReprocessAcceptanceRecording() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["MYMAN_ACCEPTANCE_FOLDER"], let id = env["MYMAN_RECOVERY_ID"] else {
            throw XCTSkip("Opt-in acceptance against a copied recording")
        }
        let root = URL(fileURLWithPath: folder)
        let db = try DatabaseQueue(path: root.appendingPathComponent("myman-backup.sqlite").path)
        let saved = try await db.read { try Meeting.fetchOne($0, key: id) }
        var meeting = try XCTUnwrap(saved)
        meeting.micAudioPath = root.appendingPathComponent(id + "-you.wav").path
        meeting.systemAudioPath = root.appendingPathComponent(id + "-others.wav").path
        meeting.endedAt = meeting.startedAt.addingTimeInterval(Double(max(MeetingTranscriptCheckpoint.samples(at: meeting.micAudioPath), MeetingTranscriptCheckpoint.samples(at: meeting.systemAudioPath))) / 16000)
        let result = try await MeetingTranscriptionWorker().process(.init(record: meeting, micPath: meeting.micAudioPath, systemPath: meeting.systemAudioPath, candidates: .none, attendees: [], regenerating: true))
        meeting.transcript = result.transcript
        meeting.originalTranscript = result.originalTranscript
        meeting.kind = result.kind.rawValue
        try JSONEncoder().encode(meeting).write(to: root.appendingPathComponent("acceptance-meeting.json"), options: .atomic)
        try meeting.transcript.write(to: root.appendingPathComponent("acceptance-transcript.md"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(meeting.transcript.count, 30_000)
        let pair = try XCTUnwrap(MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName))
        XCTAssertEqual(Set(MeetingSource.parse(meeting.transcript).map(\.speaker)), [pair.owner, pair.remote])
        print("ACCEPTANCE_AUDIO_REPROCESSED chars=\(meeting.transcript.count)")
    }
    func testRecoverSavedAudio() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["MYMAN_RECOVERY_FOLDER"], let id = env["MYMAN_RECOVERY_ID"] else {
            throw XCTSkip("Set MYMAN_RECOVERY_FOLDER and MYMAN_RECOVERY_ID for local recovery")
        }
        let root = URL(fileURLWithPath: folder)
        let db = try DatabaseQueue(path: root.appendingPathComponent("myman-backup.sqlite").path)
        let saved = try await db.read { try Meeting.fetchOne($0, key: id) }
        var meeting = try XCTUnwrap(saved)
        let mic = root.appendingPathComponent(id + "-you.wav")
        let system = root.appendingPathComponent(id + "-others.wav")
        meeting.endedAt = meeting.startedAt.addingTimeInterval(max(
            Double((try Data(contentsOf: mic)).count - 44) / 32000, Double((try Data(contentsOf: system)).count - 44) / 32000))
        let recoveredURL = root.appendingPathComponent("recovered-meeting.json")
        if FileManager.default.fileExists(atPath: recoveredURL.path) {
            meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: recoveredURL))
        } else {
        let service = TranscriptionService()
        await service.load(kind: .parakeet)
        XCTAssertTrue(service.isReady)
        let result = await MeetingController.buildTranscriptResult(
            micPath: mic.path, systemPath: system.path, candidates: .none,
            corrections: meeting.liveCorrections,
            wallDuration: meeting.endedAt!.timeIntervalSince(meeting.startedAt),
            title: meeting.title, service: service)
        XCTAssertGreaterThan(result.transcript.count, 1000)
        meeting.transcript = result.transcript
        meeting.originalTranscript = result.originalTranscript
        meeting.kind = result.kind.rawValue
        try result.transcript.write(to: root.appendingPathComponent("recovered-transcript.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(meeting).write(to: root.appendingPathComponent("recovered-meeting.json"), options: .atomic)
        print("RECOVERY_TRANSCRIPT_SAVED chars=\(result.transcript.count)")
        }
        let source = meeting
        let analysis: MeetingAnalysis
        do {
            analysis = try await AsyncDeadline.run(seconds: 60) { await GroundedMeetingNotes.generate(source) }
        } catch {
            analysis = await GroundedMeetingNotes.generate(source, useLanguageModel: false)
        }
        meeting.summary = analysis.markdown
        meeting.analysisJSON = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
        try meeting.summary.write(to: root.appendingPathComponent("recovered-notes.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(meeting).write(to: root.appendingPathComponent("recovered-meeting.json"), options: .atomic)
        print("RECOVERY_NOTES_SAVED chars=\(meeting.summary.count)")
    }
}
