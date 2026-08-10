import FluidAudio
import Foundation

// Speaker identification for the system-audio track (the Muesli recipe):
// post-hoc diarization over the full WAV, then meeting turns get labeled by
// max time-overlap. Mic track is always "You"; the far side becomes
// "Speaker 2/3/…" in first-appearance order — or stays the single remote
// label when only one voice was there. Models download once in the
// background; until they're ready, transcripts keep that single label.

actor Diarization {
    static let shared = Diarization()

    private var manager: DiarizerManager?
    private var warming = false

    /// Kick off the one-time model download + init. Safe to call repeatedly.
    func warm() async {
        guard manager == nil, !warming else { return }
        warming = true
        defer { warming = false }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager()
            m.initialize(models: models)
            manager = m
        } catch {
            NSLog("My Man [Diarize] model load failed: \(error)")
        }
    }

    /// Speaker segments for a 16k mono WAV. Empty when models aren't ready
    /// or diarization fails — callers keep their single remote label.
    func speakerSegments(forWavAtPath path: String) async -> [(speaker: String, start: Double, end: Double)] {
        if manager == nil { await warm() }
        guard let manager else { return [] }
        let samples = WavWriter.readSamples(from: URL(fileURLWithPath: path))
        guard samples.count > 16000 else { return [] }
        do {
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
            return result.segments.map {
                (String($0.speakerId), Double($0.startTimeSeconds), Double($0.endTimeSeconds))
            }
        } catch {
            NSLog("My Man [Diarize] failed: \(error)")
            return []
        }
    }
}
