import XCTest
import GRDB
@testable import MyMan

private actor ProcessingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class MeetingProcessingTests: XCTestCase {
    @MainActor private func fixture() throws -> (DatabaseQueue, Meeting) {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: UUID().uuidString, title: "Original title",
                              startedAt: Date(timeIntervalSince1970: 1789124400),
                              transcript: "**You** [0:10]: I will send the proposal on Friday.")
        try db.write { try meeting.insert($0) }
        return (db, meeting)
    }

    @MainActor func testPreparationStartsWithoutOpeningAndSharesWorkWithReaders() async throws {
        let (db, meeting) = try fixture()
        let gate = ProcessingGate()
        let started = expectation(description: "Started before document opens")
        var calls = 0
        let service = MeetingNotesService(database: db) { _, _, progress in
            calls += 1
            await progress("Writing notes…")
            started.fulfill()
            await gate.wait()
            return "## Summary\nThe complete notes."
        }
        service.prepare(meetingID: meeting.id)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(service.stages[meeting.id], "Writing notes…")
        let first = Task { await service.notes(meetingID: meeting.id) }
        let second = Task { await service.notes(meetingID: meeting.id) }
        await gate.open()
        let values = await [first.value, second.value]
        XCTAssertEqual(values, Array(repeating: "## Summary\nThe complete notes.", count: 2))
        let reopened = await service.notes(meetingID: meeting.id)
        XCTAssertEqual(reopened, values[0])
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(service.stages.isEmpty)
    }

    @MainActor func testLateNotesCannotOverwriteManualNotes() async throws {
        let (db, meeting) = try fixture()
        let gate = ProcessingGate()
        let started = expectation(description: "Generating")
        let service = MeetingNotesService(database: db) { _, _, _ in
            started.fulfill(); await gate.wait(); return "Generated notes"
        }
        let request = Task { await service.notes(meetingID: meeting.id) }
        await fulfillment(of: [started], timeout: 2)
        try await db.write { try $0.execute(sql: "UPDATE meeting SET summary = 'My own notes' WHERE id = ?", arguments: [meeting.id]) }
        await gate.open()
        _ = await request.value
        let saved = try await db.read { try Meeting.fetchOne($0, key: meeting.id) }
        XCTAssertEqual(saved?.summary, "My own notes")
    }

    @MainActor func testDeletionCannotBeRecreatedByLateGeneration() async throws {
        let (db, meeting) = try fixture()
        let gate = ProcessingGate()
        let started = expectation(description: "Generating")
        let service = MeetingNotesService(database: db) { _, _, _ in
            started.fulfill(); await gate.wait(); return "Generated notes"
        }
        let request = Task { await service.notes(meetingID: meeting.id) }
        await fulfillment(of: [started], timeout: 2)
        _ = try await db.write { try Meeting.deleteOne($0, key: meeting.id) }
        await gate.open()
        _ = await request.value
        let count = try await db.read { try Meeting.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    @MainActor func testEditedTranscriptRejectsOldNotesAndCanGenerateFreshNotes() async throws {
        let (db, meeting) = try fixture()
        let gate = ProcessingGate()
        let started = expectation(description: "Old transcript started")
        let service = MeetingNotesService(database: db) { text, _, _ in
            if text == meeting.transcript { started.fulfill(); await gate.wait() }
            return "Notes for: " + text
        }
        let original = Task { await service.notes(meetingID: meeting.id) }
        await fulfillment(of: [started], timeout: 2)
        try await db.write { try $0.execute(sql: "UPDATE meeting SET transcript = 'Corrected transcript' WHERE id = ?", arguments: [meeting.id]) }
        let corrected = Task { await service.notes(meetingID: meeting.id) }
        await gate.open()
        _ = await original.value
        let result = await corrected.value
        XCTAssertEqual(result, "Notes for: Corrected transcript")
    }

    @MainActor func testCancellingBeforeAutosavePreventsGeneratedWrite() async throws {
        let (db, meeting) = try fixture()
        let gate = ProcessingGate()
        let started = expectation(description: "Generating")
        let service = MeetingNotesService(database: db) { _, _, _ in
            started.fulfill(); await gate.wait(); return "Late notes"
        }
        let request = Task { await service.notes(meetingID: meeting.id) }
        await fulfillment(of: [started], timeout: 2)
        service.cancel(meetingID: meeting.id)
        await gate.open()
        _ = await request.value
        let saved = try await db.read { try Meeting.fetchOne($0, key: meeting.id) }
        XCTAssertEqual(saved?.summary, "")
        XCTAssertTrue(service.stages.isEmpty)
    }

    @MainActor func testNotesJobsAreBoundedAndQueuedDeletionSkipsModel() async throws {
        let (db, first) = try fixture()
        var second = first; second.id = UUID().uuidString
        let queued = second
        try await db.write { try queued.insert($0) }
        let gate = ProcessingGate()
        let started = expectation(description: "First job started")
        var calls = 0
        let service = MeetingNotesService(database: db) { _, _, _ in
            calls += 1; started.fulfill(); await gate.wait(); return "Complete notes"
        }
        let running = Task { await service.notes(meetingID: first.id) }
        await fulfillment(of: [started], timeout: 2)
        let pending = service.prepare(meetingID: queued.id)
        XCTAssertEqual(calls, 1)
        _ = try await db.write { try Meeting.deleteOne($0, key: queued.id) }
        await gate.open()
        _ = await running.value
        _ = await pending?.value
        let result = await service.notes(meetingID: queued.id)
        XCTAssertEqual(result, "")
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testTranscriptCompletionPreservesEditsAndDeletedRows() throws {
        let (db, original) = try fixture()
        try db.write { try $0.execute(sql: "UPDATE meeting SET title = 'Renamed', summary = 'My draft', transcript = '' WHERE id = ?", arguments: [original.id]) }
        let saved = try db.write { try MeetingController.saveTranscription(original, in: $0) }
        XCTAssertEqual(saved?.title, "Renamed")
        XCTAssertEqual(saved?.summary, "My draft")
        XCTAssertEqual(saved?.transcript, original.transcript)
        try db.write { try $0.execute(sql: "UPDATE meeting SET transcript = 'Manual correction' WHERE id = ?", arguments: [original.id]) }
        let edited = try db.write { try MeetingController.saveTranscription(original, in: $0) }
        XCTAssertEqual(edited?.transcript, "Manual correction")
        _ = try db.write { try Meeting.deleteOne($0, key: original.id) }
        XCTAssertNil(try db.write { try MeetingController.saveTranscription(original, in: $0) })
    }

    func testConcurrentModelLoadsShareOneWarmupAndCacheSuccess() async {
        let loader = ModelLoadCoordinator<Int>()
        let gate = ProcessingGate()
        let started = expectation(description: "One model load")
        started.assertForOverFulfill = true
        let requests = (0..<20).map { _ in Task {
            await loader.load { started.fulfill(); await gate.wait(); return 42 }
        } }
        await fulfillment(of: [started], timeout: 2)
        await gate.open()
        for request in requests { let value = await request.value; XCTAssertEqual(value, 42) }
        let cached = await loader.load { XCTFail("Already loaded"); return nil }
        XCTAssertEqual(cached, 42)
        XCTAssertEqual(loader.value, 42)
    }

    func testFailedWarmupCanRetry() async {
        let loader = ModelLoadCoordinator<Int>()
        let failed = await loader.load { nil }
        XCTAssertNil(failed)
        let retried = await loader.load { 7 }
        XCTAssertEqual(retried, 7)
    }
}
