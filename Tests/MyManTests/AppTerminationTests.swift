import AppKit
import AVFoundation
import GRDB
import XCTest
@testable import MyMan

@MainActor private final class QuitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

final class AppTerminationTests: XCTestCase {
    @MainActor func testRepeatedQuitPreparesAndRepliesExactlyOnce() async {
        let gate = QuitGate(), coordinator = AppTerminationCoordinator()
        let finished = expectation(description: "Quit reply")
        var preparations = 0, replies = 0
        coordinator.begin(prepare: { preparations += 1 }, finish: { await gate.wait() }, reply: {
            replies += 1; finished.fulfill()
        })
        coordinator.begin(prepare: { XCTFail("Repeated preparation") }, finish: {}, reply: { XCTFail("Repeated reply") })
        XCTAssertTrue(coordinator.isTerminating)
        XCTAssertEqual(preparations, 1)
        await Task.yield()
        gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(replies, 1)
    }

    @MainActor func testQuitDeadlineDoesNotWaitForUncooperativeCleanup() async {
        let gate = QuitGate(), coordinator = AppTerminationCoordinator()
        let finished = expectation(description: "Bounded quit")
        var replies = 0
        coordinator.begin(timeout: .milliseconds(50), prepare: {}, finish: { await gate.wait() }, reply: {
            replies += 1; finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(replies, 1)
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies, 1, "Late cleanup must not reply a second time")
    }

    @MainActor func testLateMicrophonePermissionCannotStartMeetingAfterQuit() async throws {
        let gate = QuitGate()
        let permission = expectation(description: "Permission requested")
        let controller = MeetingController(requestMicrophoneAccess: {
            permission.fulfill()
            await gate.wait()
            return true
        })
        controller.toggle()
        await fulfillment(of: [permission], timeout: 2)
        XCTAssertTrue(controller.isStarting)
        controller.prepareForQuit()
        await controller.finishQuitting()
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.canStartRecording)
        XCTAssertNil(controller.activeCaptureMeetingID)
        XCTAssertFalse(AppUpdateActivity(voice: .idle, meetingStarting: controller.isStarting,
            meetingRecording: controller.phase != .idle, meetingProcessing: controller.isTranscribing).isBusy)
        do { try await controller.startForAgent(title: "Late request"); XCTFail("Should reject startup") }
        catch { }
    }

    @MainActor func testQuitEndsMeetingAndKeepsSavedMaterialWithoutStartingASR() async throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("meeting.wav")
        let writer = try XCTUnwrap(WavWriter(url: audio))
        writer.append(Array(repeating: 0.1, count: 16000)); _ = writer.close()
        let record = Meeting(id: UUID().uuidString, title: "Planning", startedAt: Date().addingTimeInterval(-60),
                             micAudioPath: audio.path, transcript: "Saved transcript", summary: "Saved notes")
        try await db.write { try record.insert($0) }
        let controller = MeetingController(recording: record, titleDatabase: db,
            transcriptionRunner: { _ in XCTFail("Quit must defer ASR") })
        MeetingTranscriptionStatus.shared.recordingIDs.insert(record.id)
        controller.prepareForQuit()
        await controller.finishQuitting()
        await controller.finishQuitting()
        let stored = try await db.read { try Meeting.fetchOne($0, key: record.id) }
        let saved = try XCTUnwrap(stored)
        XCTAssertNotNil(saved.endedAt)
        XCTAssertEqual(saved.transcript, record.transcript)
        XCTAssertEqual(saved.summary, record.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isTranscribing)
        XCTAssertFalse(MeetingTranscriptionStatus.shared.recordingIDs.contains(record.id))
    }

    @MainActor func testQuitCancelsEntireTranscriptQueue() async {
        let gate = QuitGate(), entered = expectation(description: "First job running")
        var processed: [String] = []
        let controller = MeetingController(transcriptionRunner: { job in
            processed.append(job.record.id)
            if job.record.id == "quit-first" { entered.fulfill(); await gate.wait() }
        })
        for id in ["quit-first", "quit-second", "quit-third"] {
            controller.enqueueTranscription(.init(record: Meeting(id: id, title: id, startedAt: Date(), transcript: ""),
                micPath: nil, systemPath: nil, candidates: .none, attendees: []))
        }
        await fulfillment(of: [entered], timeout: 2)
        controller.prepareForQuit()
        XCTAssertFalse(controller.isTranscribing)
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(processed, ["quit-first"])
        for id in ["quit-first", "quit-second", "quit-third"] {
            XCTAssertFalse(MeetingTranscriptionStatus.shared.isPending(id))
        }
    }

    func testClosedWavRejectsLateSamplesAndKeepsValidHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url))
        writer.append(Array(repeating: 0.25, count: 16000))
        XCTAssertEqual(writer.close(), url)
        writer.append(Array(repeating: 0.5, count: 16000))
        XCTAssertEqual(writer.close(), url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16000)
    }

    func testAudioFenceRejectsLateSessionsWithoutOpeningHardware() async {
        let audio = AudioCapture()
        audio.preventNewSessions()
        do { _ = try await audio.begin(.raw); XCTFail("Closed audio capture must reject startup") }
        catch { XCTAssertTrue(error is CancellationError) }
        await audio.shutdown()
    }

    func testQuitStopsOnlyOwnedHelpersAndRejectsNewProcesses() async throws {
        let owned = AppChildProcesses()
        let child = Process(), unrelated = Process()
        for process in [child, unrelated] {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
        }
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        try owned.run(child)
        await owned.finishQuitting()
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertThrowsError(try owned.run(Process())) { XCTAssertTrue($0 is CancellationError) }
    }

    func testQuitStopsStubbornHelperAndItsChild() async throws {
        let registry = AppChildProcesses(), helper = Process()
        let receipt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receipt); registry.forceStop() }
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", "trap '' TERM; /bin/sleep 30 & echo $! > \"$1\"; wait", "fixture", receipt.path]
        try registry.run(helper)
        let ready = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: receipt.path), Date() < ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: receipt).trimmingCharacters(in: .whitespacesAndNewlines)))
        // A failed assertion must not leave this fixture running either.
        defer { if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) } }
        registry.prepareForQuit()
        await registry.finishQuitting()
        let stopped = Date().addingTimeInterval(2)
        while (helper.isRunning || kill(childPID, 0) == 0), Date() < stopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(helper.isRunning)
        XCTAssertNotEqual(kill(childPID, 0), 0, "Descendant must not survive its app-owned helper")
    }
}
