import AVFoundation
import FluidAudio
import Foundation
#if canImport(Speech)
import Speech
#endif

// On-device speech-to-text. Two engines: Parakeet (FluidAudio/ANE, the
// default) and Apple SpeechAnalyzer (macOS 26+, zero download). Both take
// 16kHz mono Float samples and return plain text.

enum SttEngineKind: String, CaseIterable, Identifiable {
    /// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML/ANE). Fast, no
    /// hallucinated text in pauses, ~600MB one-time download, 25 languages.
    case parakeet
    /// Qwen3 ASR 1.7B int8 via FluidAudio (ANE) — the accuracy engine
    /// (~4x fewer word errors than Parakeet). macOS 15+, ~1.5GB download.
    case qwen3
    /// Apple SpeechAnalyzer, built into macOS 26+. Zero download.
    case apple

    var id: String { rawValue }

    var isAvailable: Bool {
        switch self {
        case .apple:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return true }
            #endif
            return false
        case .qwen3:
            if #available(macOS 15.0, *) { return true }
            return false
        case .parakeet:
            return true
        }
    }


}

/// Qwen3 ASR through FluidAudio (0.15.1 — the last release carrying it;
/// see docs/meeting-port-notes.md). Warmup moves the one-time ~30s CoreML
/// compile out of the first dictation.
@available(macOS 15.0, *)
final class Qwen3Engine {
    private var manager: Qwen3AsrManager?
    var isReady: Bool { manager != nil }

    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        guard manager == nil else { return }
        do {
            let modelDir = try await Qwen3AsrModels.download(variant: .int8) { p in
                progress(p.fractionCompleted)
            }
            let m = Qwen3AsrManager()
            try await m.loadModels(from: modelDir)
            _ = try? await m.transcribe(audioSamples: [Float](repeating: 0, count: 16000))
            manager = m
        } catch {
            NSLog("My Man [Qwen3] failed to load: \(error)")
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard let manager else { return "" }
        do {
            // Force English — Qwen3 is multilingual and short ambiguous audio
            // ("github") can decode into Chinese under auto-detection.
            let text = try await manager.transcribe(audioSamples: samples, language: "en")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Belt and suspenders: if CJK still dominates, it's a decode
            // hallucination, not speech — never paste it.
            let cjk = text.unicodeScalars.filter {
                (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
            }.count
            if cjk * 3 > max(text.count, 1) {
                NSLog("My Man [Qwen3] discarded CJK-dominant hallucination")
                return ""
            }
            // Qwen occasionally emits its own task-like boilerplate during
            // silence or a bad audio frame. It is not spoken text and must
            // never be pasted into the focused app.
            return TranscriptionService.discardTaskHallucination(text)
        } catch {
            NSLog("My Man [Qwen3] transcription failed: \(error)")
            return ""
        }
    }
}

final class ParakeetEngine {
    private var manager: AsrManager?
    var isReady: Bool { manager != nil }

    /// Download (first run only) and load the Parakeet CoreML models.
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        guard manager == nil else { return }
        do {
            let models = try await AsrModels.downloadAndLoad(progressHandler: { p in
                progress(p.fractionCompleted)
            })
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
        } catch {
            NSLog("My Man [Parakeet] failed to load: \(error)")
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard let manager else { return "" }
        do {
            // Fresh decoder state per utterance — recordings are independent.
            var decoderState = TdtDecoderState.make()
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("My Man [Parakeet] transcription failed: \(error)")
            return ""
        }
    }
}

#if compiler(>=6.2)
// SpeechAnalyzer is introduced by the macOS 26 SDK. Availability alone is
// insufficient here: an older SDK cannot even type-check these symbols.
@available(macOS 26.0, *)
final class AppleSpeechEngine {
    private(set) var isReady = false
    private let locale = Locale(identifier: "en_US")

    func load() async {
        do {
            let supported = await SpeechTranscriber.supportedLocales
            guard supported.contains(where: {
                $0.identifier(.bcp47) == locale.identifier(.bcp47)
            }) else { return }
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [], attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            isReady = true
        } catch {
            NSLog("My Man [AppleSpeech] failed to prepare: \(error)")
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard isReady else { return "" }
        do {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [], attributeOptions: []
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let buffer = Self.makeBuffer(samples: samples, targetFormat: analyzerFormat) else {
                return ""
            }
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            inputBuilder.finish()

            async let collected: String = {
                var text = ""
                for try await result in transcriber.results {
                    text += String(result.text.characters)
                }
                return text
            }()

            try await analyzer.start(inputSequence: inputSequence)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return (try await collected).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("My Man [AppleSpeech] transcription failed: \(error)")
            return ""
        }
    }

    private static func makeBuffer(samples: [Float], targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            sourceBuffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        if sourceFormat == targetFormat { return sourceBuffer }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if conversionError != nil { return nil }
        return outBuffer
    }
}
#endif

/// Engine facade — only the active engine loads, so users never download
/// models they don't use. Shared by dictation and meeting transcription.
final class TranscriptionService {
    static let shared = TranscriptionService()

    let parakeet = ParakeetEngine()
    private var appleEngine: AnyObject?
    private var qwen3Engine: AnyObject?
    private(set) var kind: SttEngineKind = .parakeet

    @available(macOS 15.0, *)
    private var qwen3: Qwen3Engine {
        if let engine = qwen3Engine as? Qwen3Engine { return engine }
        let engine = Qwen3Engine()
        qwen3Engine = engine
        return engine
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var apple: AppleSpeechEngine {
        if let engine = appleEngine as? AppleSpeechEngine { return engine }
        let engine = AppleSpeechEngine()
        appleEngine = engine
        return engine
    }
    #endif

    /// True once the accuracy engine is actually loaded — only then does
    /// dictation switch to it. Never blocks a dictation on a 1.5GB download.
    var qwen3Ready: Bool {
        if #available(macOS 15.0, *) { return qwen3.isReady }
        return false
    }

    /// Warm Qwen3 in the background (app launch). Dictation picks it up on
    /// the first take after it finishes.
    func warmQwen3() {
        guard #available(macOS 15.0, *) else { return }
        let engine = qwen3
        Task.detached(priority: .utility) {
            await engine.load()
            NSLog("My Man [Qwen3] background warmup finished, ready: \(engine.isReady)")
        }
    }

    /// Best engine for dictation RIGHT NOW — accuracy if loaded, speed otherwise.
    var dictationKind: SttEngineKind {
        qwen3Ready ? .qwen3 : .parakeet
    }

    var isReady: Bool {
        switch kind {
        case .parakeet: return parakeet.isReady
        case .qwen3:
            if #available(macOS 15.0, *) { return qwen3.isReady }
            return false
        case .apple:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return apple.isReady }
            #endif
            return false
        }
    }

    func load(kind: SttEngineKind = .parakeet,
              progress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        self.kind = kind
        switch kind {
        case .parakeet:
            await parakeet.load(progress: progress)
        case .qwen3:
            if #available(macOS 15.0, *) {
                await qwen3.load(progress: progress)
                // Accuracy engine failed to arrive → fall back to speed.
                if !qwen3.isReady {
                    self.kind = .parakeet
                    await parakeet.load(progress: progress)
                }
            } else {
                self.kind = .parakeet
                await parakeet.load(progress: progress)
            }
        case .apple:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                await apple.load()
                return
            } else {
                // Fall through to the portable engine below.
            }
            #endif
            self.kind = .parakeet
            await parakeet.load(progress: progress)
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        let text: String
        switch kind {
        case .parakeet: text = await parakeet.transcribe(samples)
        case .qwen3:
            if #available(macOS 15.0, *) { text = await qwen3.transcribe(samples) }
            else { text = await parakeet.transcribe(samples) }
        case .apple:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { text = await apple.transcribe(samples) }
            else { text = "" }
            #else
            text = ""
            #endif
        }
        return Self.discardTaskHallucination(text)
    }

    /// Some ASR decoders occasionally emit their own translation task label
    /// instead of speech. Run this after *every* engine, not just Qwen, so a
    /// model fallback cannot paste the phrase into another app.
    static func discardTaskHallucination(_ text: String) -> String {
        let normalized = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        // Match on the TAIL alone. The decoder garbles the words in front of
        // it differently every time ("opera", "oper", "agnis the oper"), and
        // an earlier list of full phrases let those variants through into
        // real documents. Nobody dictates this phrase on purpose.
        let taskFragments = [
            "to english text", "into english text",
            "to english language", "into english language",
        ]
        guard taskFragments.contains(where: normalized.contains) else { return text }
        NSLog("My Man [ASR] discarded English-task hallucination")
        return ""
    }
}
