import AVFoundation
import XCTest
@testable import MyMan

final class DictationLatencyTests: XCTestCase {
    func testAlreadyPunctuatedNeutralSpeechSkipsGeneration() {
        XCTAssertFalse(DictationCleanup.requiresModelPolish("Please send the revised project plan tomorrow.", tone: .neutral))
        XCTAssertFalse(DictationCleanup.requiresModelPolish("The total is $92,000, with 4.5% churn.", tone: .neutral))
        XCTAssertTrue(DictationCleanup.requiresModelPolish("Send it Tuesday, no wait, Wednesday.", tone: .neutral))
        XCTAssertTrue(DictationCleanup.requiresModelPolish("Revenue increased forty percent.", tone: .neutral))
        XCTAssertTrue(DictationCleanup.requiresModelPolish("Please send the plan.", tone: .professional))
        XCTAssertTrue(DictationCleanup.requiresModelPolish("Please send the plan.", tone: .casual))
        XCTAssertFalse(DictationCleanup.requiresModelPolish("uh keep exactly these words", tone: .verbatim))
    }

    func testSlowPolishCannotHoldDictationOrReplaceTheFallbackLater() async {
        let start = Date()
        let text = await DictationCleanup.boundedPolish(fallback: "Preserve my words.", seconds: 0.02) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume(returning: "Late rewrite.") }
            }
        }
        XCTAssertEqual(text, "Preserve my words.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testQuickPolishIsRetained() async {
        let text = await DictationCleanup.boundedPolish(fallback: "Original.") { "Cleaned." }
        XCTAssertEqual(text, "Cleaned.")
    }

    func testOptInLocalTiming() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYMAN_DICTATION_BENCHMARK"],
              path.hasPrefix("/private/tmp/myman-dictation-speed") else {
            throw XCTSkip("Opt-in synthetic audio benchmark")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        let service = TranscriptionService()
        let load = Date()
        await service.load(kind: .parakeet)
        XCTAssertTrue(service.isReady)
        print("DICTATION_TIMING load_ms=\(Int(Date().timeIntervalSince(load) * 1000)) audio_s=\(Double(samples.count) / 16000)")
        for run in 1...2 {
            let began = Date()
            let raw = await service.transcribe(samples)
            let recognition = Date().timeIntervalSince(began)
            let cleanup = Date()
            let text = await DictationCleanup.clean(raw)
            print("DICTATION_TIMING run=\(run) asr_ms=\(Int(recognition * 1000)) cleanup_ms=\(Int(Date().timeIntervalSince(cleanup) * 1000)) text=\(text)")
            XCTAssertFalse(text.isEmpty)
        }
    }
}
