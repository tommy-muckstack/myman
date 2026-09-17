import AVFoundation
import GRDB
import XCTest
@testable import MyMan

private actor TranscriptGate {
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

final class MeetingBackgroundTranscriptionTests: XCTestCase {
    func testBackgroundWorkerWithSyntheticSpeech() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYMAN_LIVE_SYNTHETIC_AUDIO"] else {
            throw XCTSkip("Set MYMAN_LIVE_SYNTHETIC_AUDIO to exercise the background speech model")
        }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: buffer)
        XCTAssertEqual(source.processingFormat.sampleRate, 16000)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url))
        writer.append(samples)
        _ = writer.close()
        let dictationEngine = TranscriptionService.shared.kind
        let meeting = Meeting(id: "synthetic", title: "Synthetic", startedAt: Date(), transcript: "")
        let worker = MeetingTranscriptionWorker()
        let result = try await worker.process(.init(record: meeting, micPath: url.path, systemPath: nil,
                                                candidates: .none, attendees: []))
        XCTAssertTrue(result.transcript.lowercased().contains("proposal"), result.transcript)
        XCTAssertEqual(TranscriptionService.shared.kind, dictationEngine,
                       "Processing a meeting must not change dictation's engine")
    }

    @MainActor func testStopFreesRecorderWhileTranscriptIsStillRunning() async throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: "first", title: "First call", startedAt: Date(), transcript: "")
        try await db.write { try meeting.insert($0) }
        let started = expectation(description: "Processing started")
        let gate = TranscriptGate()
        let controller = MeetingController(recording: meeting, titleDatabase: db, transcriptionRunner: { job in
            XCTAssertEqual(job.record.id, meeting.id)
            XCTAssertNotNil(job.record.endedAt)
            started.fulfill()
            await gate.wait()
        })
        controller.requestStopRecording()
        controller.confirmStopRecording()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.canStartRecording)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isTranscribing)
        XCTAssertTrue(controller.canStartRecording)

        // A later recorder state must survive completion of the old job.
        let nextStart = Date()
        controller.phase = .recording(start: nextStart)
        controller.setTitleEditorVisible(true)
        await gate.open()
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.phase, .recording(start: nextStart))
        XCTAssertTrue(controller.titleEditorVisible)
    }

    @MainActor func testBackToBackTranscriptsStaySerialEvenWithIdenticalTitles() async {
        let firstStarted = expectation(description: "First started")
        let secondStarted = expectation(description: "Second started")
        let firstGate = TranscriptGate()
        let secondGate = TranscriptGate()
        var ids: [String] = []
        let controller = MeetingController(transcriptionRunner: { job in
            ids.append(job.record.id)
            if job.record.id == "first" {
                firstStarted.fulfill(); await firstGate.wait()
            } else {
                secondStarted.fulfill(); await secondGate.wait()
            }
        })
        for id in ["first", "second"] {
            let meeting = Meeting(id: id, title: "Daily call", startedAt: Date(), transcript: "")
            controller.enqueueTranscription(.init(record: meeting, micPath: nil, systemPath: nil,
                                                   candidates: .none, attendees: []))
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(ids, ["first"])
        XCTAssertEqual(controller.transcribingTitles.count, 2)
        XCTAssertTrue(controller.canStartRecording)
        await firstGate.open()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(ids, ["first", "second"])
        XCTAssertEqual(controller.transcribingTitles.count, 1)
        await secondGate.open()
        await waitUntilFinished(controller)
        XCTAssertTrue(controller.canStartRecording)
    }

    @MainActor private func waitUntilFinished(_ controller: MeetingController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.isTranscribing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isTranscribing)
    }
}
