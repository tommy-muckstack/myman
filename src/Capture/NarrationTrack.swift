import AVFoundation
import Foundation

// Screen-recording narration, captured by US instead of ScreenCaptureKit.
// SCK's captureMicrophone echo-cancels the mic against system audio, which
// leaves narration watery, muffled, and quiet no matter which device it
// uses. Our own raw AudioCapture session (the dictation pipeline's engine,
// minus voice processing) hears the mic exactly; the take is peak-normalized
// once at the end and muxed into the movie as its own PCM track.

@MainActor
final class NarrationTrack {
    private var session: UUID?
    private var writer: WavWriter?
    private var drainTimer: Timer?
    private var muted = false
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

    func start(alongside movieURL: URL, videoStartedAt: Date = Date()) {
        stopDiscarding()
        guard let id = try? AudioCapture.shared.begin(.raw) else { return }
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

    /// Close out the take: final drain, whole-take peak normalization, then
    /// mux into the movie as a second audio track. Returns when the movie is
    /// final. The sidecar WAV is deleted on success and kept beside the
    /// movie on mux failure — narration must never be silently lost.
    func finish(into movieURL: URL) async {
        guard let session else { return }
        drain()
        _ = AudioCapture.shared.end(session)
        self.session = nil
        drainTimer?.invalidate()
        drainTimer = nil
        guard let wavURL = writer?.close() else {
            writer = nil
            return
        }
        writer = nil
        Self.normalize(wavURL: wavURL)
        if await Self.mux(narration: wavURL, into: movieURL,
                          atOffsetSeconds: startOffsetSeconds) {
            try? FileManager.default.removeItem(at: wavURL)
        } else {
            NSLog("My Man [Record] narration mux failed — WAV kept at \(wavURL.path)")
            Analytics.track("recording_narration_mux_failed")
        }
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

    /// Passthrough remux: all of the movie's tracks plus the narration WAV
    /// as an additional PCM audio track. No video re-encode.
    private static func mux(narration wavURL: URL, into movieURL: URL,
                            atOffsetSeconds offset: Double) async -> Bool {
        let movie = AVURLAsset(url: movieURL)
        let wav = AVURLAsset(url: wavURL)
        let composition = AVMutableComposition()
        do {
            let movieDuration = try await movie.load(.duration)
            for track in try await movie.load(.tracks) {
                guard let target = composition.addMutableTrack(
                    withMediaType: track.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try target.insertTimeRange(
                    CMTimeRange(start: .zero, duration: movieDuration),
                    of: track, at: .zero)
            }
            guard let narrationSource = try await wav.loadTracks(withMediaType: .audio).first,
                  let narrationTarget = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
            let wavDuration = try await wav.load(.duration)
            let start = CMTime(seconds: offset, preferredTimescale: 600)
            let available = CMTimeSubtract(movieDuration, start)
            try narrationTarget.insertTimeRange(
                CMTimeRange(start: .zero,
                            duration: CMTimeMinimum(wavDuration, available)),
                of: narrationSource, at: start)

            guard let export = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetPassthrough) else { return false }
            let temp = movieURL.deletingLastPathComponent()
                .appendingPathComponent(".mux-\(UUID().uuidString).mov")
            export.outputURL = temp
            export.outputFileType = .mov
            await export.export()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            _ = try FileManager.default.replaceItemAt(movieURL, withItemAt: temp)
            return true
        } catch {
            NSLog("My Man [Record] mux error: \(error)")
            return false
        }
    }
}
