import AppKit
import SwiftUI
import GRDB
import XCTest
@testable import MyMan

private actor RetryPreparationReader: LiveMeetingTranscriptReading {
    var attempts = 0
    func prepare() async throws {
        attempts += 1
        if attempts < 3 { throw CocoaError(.fileReadUnknown) }
    }
    func next() async throws -> [MeetingTurn] { [] }
}

final class MeetingResilienceTests: XCTestCase {
    func testDeadlineReturnsEvenWhenOperationIgnoresCancellation() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await AsyncDeadline.run(seconds: 0.02) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume(returning: 1) }
                }
            }
            XCTFail("Must time out")
        } catch { XCTAssertTrue(error is AsyncDeadline.TimedOut) }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))
        // Late completion must not double-resume the continuation.
        try await Task.sleep(for: .milliseconds(350))
    }

    func testCheckpointRestoresWordsAndOffsetsAndRejectsChangedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("call-you.wav")
        let writer = try XCTUnwrap(WavWriter(url: audio))
        writer.append([Float](repeating: 0.1, count: 16000)); _ = writer.close()
        let url = try XCTUnwrap(MeetingTranscriptCheckpoint.url(micPath: audio.path, systemPath: nil))
        let turn = MeetingTurn(start: 0, end: 1, speaker: "You", text: "Keep these words")
        let saved = MeetingTranscriptCheckpoint(micPath: audio.path, micOffset: 16000, turns: [turn])
        try saved.save(to: url)
        let restored = try XCTUnwrap(MeetingTranscriptCheckpoint.load(at: url, micPath: audio.path, systemPath: nil))
        XCTAssertEqual(restored.turns, [turn]); XCTAssertEqual(restored.micOffset, 16000)
        XCTAssertThrowsError(try MeetingTranscriptCheckpoint.load(at: url, micPath: "different.wav", systemPath: nil))
        try Data(repeating: 0, count: 44).write(to: audio)
        XCTAssertThrowsError(try MeetingTranscriptCheckpoint.load(at: url, micPath: audio.path, systemPath: nil))
    }

    func testFinalReadIncludesTailThatLiveReaderWaitedOn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url))
        writer.append([Float](repeating: 0.1, count: 2000)); _ = writer.close()
        XCTAssertNil(try LiveMeetingTranscriptReader.readChunk(at: url, offset: 0))
        XCTAssertEqual(try LiveMeetingTranscriptReader.readChunk(at: url, offset: 0, final: true)?.samples.count, 2000)
    }

    @MainActor func testLivePreparationRetriesWithoutUserIntervention() async throws {
        let reader = RetryPreparationReader()
        let transcript = LiveMeetingTranscript(automaticRetryDelays: [0.01, 0.01])
        transcript.start(reader: reader, ownerName: "Alex", candidates: .none)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while transcript.status != .live, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transcript.status, .live)
        let count = await reader.attempts
        XCTAssertEqual(count, 3)
        transcript.stop()
    }

    @MainActor func testEmptyRecognitionRetriesAndRetainsAudioAndMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("call-you.wav")
        let writer = try XCTUnwrap(WavWriter(url: path))
        writer.append([Float](repeating: 0.1, count: 16000)); _ = writer.close()
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let meeting = Meeting(id: UUID().uuidString, title: "Keep this call", startedAt: Date().addingTimeInterval(-3900),
                              endedAt: Date(), micAudioPath: path.path, transcript: "")
        try await db.write { try meeting.insert($0) }
        var attempts = 0
        let controller = MeetingController(titleDatabase: db, transcriptionProcessor: { _ in
            attempts += 1
            return MeetingTranscriptResult(transcript: "", originalTranscript: "", kind: .meeting)
        })
        controller.enqueueTranscription(.init(record: meeting, micPath: path.path, systemPath: nil, candidates: .none, attendees: []))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isTranscribing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.isTranscribing)
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let count = try await db.read { try Meeting.fetchCount($0) }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try MeetingProcessingRecord.load(for: meeting)?.attempts, 3)
        XCTAssertEqual(try MeetingProcessingRecord.load(for: meeting)?.phase, .failed)
        XCTAssertNotNil(MeetingTranscriptionStatus.shared.failures[meeting.id])
        // A relaunch cannot reset the persisted budget and crash-loop forever.
        controller.enqueueTranscription(.init(record: meeting, micPath: path.path, systemPath: nil, candidates: .none, attendees: []))
        while controller.isTranscribing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(attempts, 3)
    }

    @MainActor func testRegenerationCannotOverwriteEditsMadeWhileProcessing() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        var meeting = Meeting(id: "regen", title: "Keep my title", startedAt: Date(), transcript: "First transcript", summary: "My notes")
        try db.write { try meeting.insert($0) }
        meeting.transcript = "Regenerated transcript"
        let replaced = try db.write { try MeetingController.saveTranscription(meeting, in: $0, replacing: "First transcript") }
        XCTAssertEqual(replaced?.transcript, "Regenerated transcript")
        XCTAssertEqual(replaced?.summary, "My notes")
        try db.write { try $0.execute(sql: "UPDATE meeting SET transcript = 'My correction' WHERE id = 'regen'") }
        let guarded = try db.write { try MeetingController.saveTranscription(meeting, in: $0, replacing: "Regenerated transcript") }
        XCTAssertEqual(guarded?.transcript, "My correction")
    }

    @MainActor func testNotesRetryAndExplicitRegenerationKeepExistingNotesUntilSuccess() async throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let meeting = Meeting(id: "notes-retry", title: "Call", startedAt: Date(), transcript: "**You** [0:01]: Send the proposal.", summary: "Existing notes")
        try await db.write { try meeting.insert($0) }
        var calls = 0
        let service = MeetingNotesService(database: db) { _, _, _ in
            calls += 1
            let current = try? await db.read { try Meeting.fetchOne($0, key: meeting.id) }
            XCTAssertEqual(current?.summary, "Existing notes")
            return calls < 3 ? "" : "Regenerated notes"
        }
        let result = await service.regenerate(meetingID: meeting.id)
        XCTAssertEqual(result, "Regenerated notes"); XCTAssertEqual(calls, 3)
    }

    @MainActor func testFailureViewRendersWithRecoveryActions() async throws {
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let meeting = Meeting(id: "recovery-view", title: "Customer conversation", startedAt: Date(), transcript: "")
        try await db.write { try meeting.insert($0) }
        MeetingTranscriptionStatus.shared.fail(meetingID: meeting.id, message: "Transcription needs another try. Your recording is saved.")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: MeetingDocumentView(meeting: meeting, database: db, automaticallySummarize: false))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/myman-recovery-actions.png"))
    }
}
