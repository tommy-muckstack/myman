import AVFoundation
import Foundation

// Screen-recording narration, captured by US instead of ScreenCaptureKit.
// SCK's captureMicrophone echo-cancels the mic against system audio, which
// leaves narration watery, muffled, and quiet no matter which device it
// uses. Our own raw AudioCapture session (the dictation pipeline's engine,
// minus voice processing) hears the mic exactly; the take is peak-normalized
// once at the end and mixed into the movie's single shareable audio track
// by `ShareReadyMovie`.

@MainActor
final class NarrationTrack {
    private var session: UUID?
    private var writer: WavWriter?
    private var drainTimer: Timer?
    private var muted = false
    private var isShuttingDown = false

    /// Preserve the sidecar if video finalization cannot finish before quit.
    func preserveForQuit() {
        isShuttingDown = true
        drain()
        if let session { _ = AudioCapture.shared.end(session) }
        session = nil
        drainTimer?.invalidate(); drainTimer = nil
        _ = writer?.close(); writer = nil
    }
    /// Seconds of video that had already elapsed when this take began —
    /// the mux inserts the track here (nonzero when the mic was switched
    /// on mid-recording).
    private var startOffsetSeconds: Double = 0

    var isActive: Bool { session != nil }

    /// 0...1 level for the pill meter.
    func currentLevel() -> CGFloat {
        guard let session, !muted else { return 0 }
        return CGFloat(min(1, AudioCapture.shared.currentLevel(for: session) * 6))
    }

    func start(alongside movieURL: URL, videoStartedAt: Date = Date()) async {
        guard !isShuttingDown else { return }
        stopDiscarding()
        guard let id = try? await AudioCapture.shared.begin(.raw) else { return }
        guard !isShuttingDown, !Task.isCancelled else {
            _ = AudioCapture.shared.end(id)
            return
        }
        startOffsetSeconds = max(0, Date().timeIntervalSince(videoStartedAt))
        let rate = UInt32(AudioCapture.shared.nativeSampleRate())
        let url = movieURL.deletingPathExtension().appendingPathExtension("narration.wav")
        guard let wav = WavWriter(url: url, sampleRate: rate) else {
            _ = AudioCapture.shared.end(id)
            return
        }
        session = id
        writer = wav
        muted = false
        drainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }

    func setMuted(_ value: Bool) {
        drain() // flush what was heard up to the toggle
        muted = value
    }

    private func drain() {
        guard let session else { return }
        let native = AudioCapture.shared.drainNative(session)
        // Muted stretches write ZEROS, not nothing — dropping them would
        // shift everything after an unmute earlier and desync the track.
        writer?.append(muted
                       ? [Float](repeating: 0, count: native.samples.count)
                       : native.samples)
    }

    /// A closed, peak-normalized take and where it starts on the video's timeline.
    struct Take {
        var wavURL: URL
        var offsetSeconds: Double
    }

    /// Close out the take: final drain + whole-take peak normalization.
    /// Returns nil when the mic was never on for this segment. The WAV is
    /// the caller's to mix in (see `ShareReadyMovie`) and delete; it stays
    /// beside the movie if that fails — narration must never be silently lost.
    func close() -> Take? {
        guard let session else { return nil }
        drain()
        _ = AudioCapture.shared.end(session)
        self.session = nil
        drainTimer?.invalidate()
        drainTimer = nil
        guard let wavURL = writer?.close() else {
            writer = nil
            return nil
        }
        writer = nil
        Self.normalize(wavURL: wavURL)
        return Take(wavURL: wavURL, offsetSeconds: startOffsetSeconds)
    }

    /// Abandon the take (restart/discard): stop capturing, delete the WAV.
    func stopDiscarding() {
        if let session { _ = AudioCapture.shared.end(session) }
        session = nil
        drainTimer?.invalidate()
        drainTimer = nil
        if let url = writer?.close() { try? FileManager.default.removeItem(at: url) }
        writer = nil
    }

    /// One gain over the whole take, streamed in 4MB slices — quiet raw mic
    /// audio comes up to listening level without per-chunk pumping. Gain is
    /// capped so a near-silent take doesn't become amplified room hiss.
    private static func normalize(wavURL: URL, targetPeak: Float = 0.9, maxGain: Float = 12) {
        guard let handle = try? FileHandle(forUpdating: wavURL) else { return }
        defer { try? handle.close() }
        let headerBytes: UInt64 = 44
        let sliceBytes = 4 << 20
        var peak: Int16 = 0
        var offset = headerBytes
        while true {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: sliceBytes), !data.isEmpty else { break }
            data.withUnsafeBytes { raw in
                for value in raw.bindMemory(to: Int16.self) {
                    peak = max(peak, value == Int16.min ? Int16.max : abs(value))
                }
            }
            offset += UInt64(data.count)
            if data.count < sliceBytes { break }
        }
        guard peak > 40 else { return } // effectively silence — leave it
        let gain = min(maxGain, targetPeak * 32767 / Float(peak))
        guard gain > 1.05 else { return }
        offset = headerBytes
        while true {
            try? handle.seek(toOffset: offset)
            guard var data = try? handle.read(upToCount: sliceBytes), !data.isEmpty else { break }
            data.withUnsafeMutableBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<samples.count {
                    let scaled = Float(samples[i]) * gain
                    samples[i] = Int16(max(-32767, min(32767, scaled)))
                }
            }
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: data)
            offset += UInt64(data.count)
            if data.count < sliceBytes { break }
        }
    }
}
