import FluidAudio
import Foundation

// Speaker identification for the system-audio track (the Muesli recipe):
// post-hoc diarization over the full WAV, then meeting turns get labeled by
// max time-overlap. Mic track is always "You"; the far side becomes
// "Speaker 2/3/…" in first-appearance order — or stays the single remote
// label when only one voice was there. Models download once in the
// background; transcription joins warmup before assigning speaker labels.

actor Diarization {
    static let shared = Diarization()

    private var manager: DiarizerManager?
    private var warmup: Task<Void, Never>?

    /// Kick off the one-time model download + init. Safe to call repeatedly.
    func warm() async {
        guard manager == nil else { return }
        if let warmup { await warmup.value; return }
        let task = Task { await loadModels() }
        warmup = task
        await task.value
        warmup = nil
    }

    private func loadModels() async {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager()
            m.initialize(models: models)
            manager = m
        } catch {
            NSLog("My Man [Diarize] model load failed: \(error)")
        }
    }

    /// Speaker segments for a 16k mono WAV. Empty when models cannot load
    /// or diarization fails — callers keep their single remote label.
    func speakerSegments(forWavAtPath path: String) async -> [(speaker: String, start: Double, end: Double)] {
        if manager == nil { await warm() }
        guard let manager else { return [] }
        let samples = WavWriter.readSamples(from: URL(fileURLWithPath: path))
        guard samples.count > 16000 else { return [] }
        do {
            let profiles = (try? VoiceProfiles.all()) ?? []
            let known = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
            manager.speakerManager.reset()
            manager.initializeKnownSpeakers(profiles.filter { $0.embedding.count == 256 }.map {
                Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
            })
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
            return result.segments.map {
                (known[String($0.speakerId)].map { "known:" + $0 } ?? String($0.speakerId),
                 Double($0.startTimeSeconds), Double($0.endTimeSeconds))
            }
        } catch {
            NSLog("My Man [Diarize] failed: \(error)")
            return []
        }
    }
}
