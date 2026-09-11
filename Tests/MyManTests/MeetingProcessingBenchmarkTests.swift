import AVFoundation
import XCTest
@testable import MyMan

/// Opt-in only: uses installed local models and an explicitly supplied
/// synthetic speech fixture. CI/unit tests never download or load models.
final class MeetingProcessingBenchmarkTests: XCTestCase {
    @MainActor func testSpeakerOverlapBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAN_SYNTHETIC_BENCHMARK_AUDIO"] else {
            throw XCTSkip("Set MAN_SYNTHETIC_BENCHMARK_AUDIO to a synthetic 16kHz mono audio file")
        }
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(audio.processingFormat.sampleRate, 16000)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]),
                                                count: Int(buffer.frameLength)))
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("man-benchmark-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let writer = try XCTUnwrap(WavWriter(url: wav))
        writer.append(samples)
        XCTAssertNotNil(writer.close())
        await TranscriptionService.shared.load(kind: .qwen3)
        XCTAssertEqual(TranscriptionService.shared.kind, .qwen3, "Compare the accuracy engine, not its fallback")
        await Diarization.shared.warm()
        // Warm both pipelines before timing; alternate order to reduce bias.
        let reference = await MeetingController.buildTranscript(micPath: nil, systemPath: wav.path,
                                                               overlapDiarization: false)
        XCTAssertFalse(reference.isEmpty)
        for overlap in [true, false, false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = await MeetingController.buildTranscript(micPath: nil, systemPath: wav.path,
                                                                overlapDiarization: overlap)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(result, reference, "Scheduling must preserve the transcript and speaker labels")
            print("MEETING_BENCHMARK overlap=\(overlap) seconds=\(String(format: "%.3f", seconds)) audio_seconds=\(Double(samples.count) / 16000)")
        }
    }
}
