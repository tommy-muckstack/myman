import AVFoundation
import Foundation

// The file a recording becomes once it is saved: an .mp4 with ONE video
// track and ONE stereo AAC audio track that already mixes system audio and
// narration. That is the shape every player agrees on. Our previous master
// (an HEVC .mov with system audio on one track and raw-PCM narration on a
// second) played perfectly in QuickTime and silently lost the voice track
// everywhere else — browsers, Slack, and most web players only decode the
// first audio track, and several of them refuse PCM-in-MOV outright.
//
// Video is never re-encoded here: the screen stream passes through as
// captured; only the audio is mixed and encoded once.

enum ShareReadyMovie {
    static func shareURL(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("mp4")
    }

    /// Level the recorded system audio sits at under narration. Narration is
    /// peak-normalized already; system sound is held back a touch so the
    /// sum does not clip on a loud notification during a sentence.
    static let systemAudioGainUnderNarration: Float = 0.8

    /// Turns `movie` (the capture as written by ScreenCaptureKit) plus an
    /// optional narration WAV into the share-ready .mp4 beside it. Returns
    /// the new file; the inputs are left in place for the caller to remove.
    @discardableResult
    static func finalize(movie movieURL: URL, narration wavURL: URL?,
                         narrationOffsetSeconds offset: Double = 0,
                         to destination: URL? = nil) async throws -> URL {
        let output = destination ?? shareURL(for: movieURL)
        let movie = AVURLAsset(url: movieURL)
        let movieDuration = try await movie.load(.duration)
        guard movieDuration.seconds.isFinite, movieDuration.seconds > 0,
              let video = try await movie.loadTracks(withMediaType: .video).first else {
            throw AgentError("INVALID_VIDEO", "Recording has no playable video track.")
        }
        let folder = movieURL.deletingLastPathComponent()
        var temporaries: [URL] = []
        defer { for url in temporaries { try? FileManager.default.removeItem(at: url) } }

        // 1. Every audio source → one stereo AAC track.
        let mixed = try await mixAudio(of: movie, duration: movieDuration, narration: wavURL,
                                       narrationOffsetSeconds: offset, in: folder)
        if let mixed { temporaries.append(mixed) }

        // 2. Passthrough video + the mixed track → .mp4.
        let composition = AVMutableComposition()
        guard let videoTarget = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AgentError("EXPORT_FAILED", "Cannot allocate the video track.")
        }
        let videoRange = try await video.load(.timeRange)
        try videoTarget.insertTimeRange(
            CMTimeRangeGetIntersection(videoRange, otherRange: CMTimeRange(start: .zero, duration: movieDuration)),
            of: video, at: videoRange.start)
        videoTarget.preferredTransform = try await video.load(.preferredTransform)
        if let mixed {
            let audio = AVURLAsset(url: mixed)
            if let source = try await audio.loadTracks(withMediaType: .audio).first,
               let target = composition.addMutableTrack(
                   withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let duration = CMTimeMinimum(try await audio.load(.duration), movieDuration)
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            }
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AgentError("EXPORT_FAILED", "Cannot assemble the shareable recording.")
        }
        let temp = folder.appendingPathComponent(".share-\(UUID().uuidString).mp4")
        temporaries.append(temp)
        export.outputURL = temp
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true // moov up front: streams the moment it lands in Slack
        await export.export()
        guard export.status == .completed else {
            throw AgentError("EXPORT_FAILED", export.error?.localizedDescription ?? "Shareable recording could not be written.")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
        return output
    }

    /// Sums the movie's audio tracks and the narration (inserted at its
    /// offset) into one AAC .m4a. Nil when there is nothing to hear.
    private static func mixAudio(of movie: AVURLAsset, duration: CMTime, narration wavURL: URL?,
                                 narrationOffsetSeconds offset: Double, in folder: URL) async throws -> URL? {
        let composition = AVMutableComposition()
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        let systemTracks = try await movie.loadTracks(withMediaType: .audio)
        var narrationTrack: AVAssetTrack?
        var narrationDuration = CMTime.zero
        // A track only weakly references its asset: the WAV asset must
        // outlive the insert below or the composition fails with -12780.
        var wav: AVURLAsset?
        if let wavURL, FileManager.default.fileExists(atPath: wavURL.path) {
            let asset = AVURLAsset(url: wavURL)
            wav = asset
            narrationTrack = try await asset.loadTracks(withMediaType: .audio).first
            narrationDuration = try await asset.load(.duration)
        }
        defer { withExtendedLifetime(wav) {} }
        guard !systemTracks.isEmpty || narrationTrack != nil else { return nil }

        for track in systemTracks {
            guard let target = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = try await track.load(.timeRange)
            let available = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: duration))
            guard available.duration.seconds > 0 else { continue }
            try target.insertTimeRange(available, of: track, at: available.start)
            let gain = AVMutableAudioMixInputParameters(track: target)
            gain.setVolume(narrationTrack == nil ? 1 : systemAudioGainUnderNarration, at: .zero)
            parameters.append(gain)
        }
        if let narrationTrack,
           let target = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let start = CMTime(seconds: max(0, offset), preferredTimescale: 600)
            let available = CMTimeSubtract(duration, start)
            if available.seconds > 0 {
                try target.insertTimeRange(
                    CMTimeRange(start: .zero, duration: CMTimeMinimum(narrationDuration, available)),
                    of: narrationTrack, at: start)
                let gain = AVMutableAudioMixInputParameters(track: target)
                gain.setVolume(1, at: .zero)
                parameters.append(gain)
            }
        }
        guard !parameters.isEmpty else { return nil }
        mix.inputParameters = parameters
        let temp = folder.appendingPathComponent(".mix-\(UUID().uuidString).m4a")
        try await encodeAAC(composition, mix: mix, to: temp)
        return temp
    }

    /// Decodes every track of `composition` through one mixer and writes a
    /// stereo 48 kHz AAC file. (AVAssetExportSession's M4A preset refuses
    /// mono PCM sources, which is exactly what the narration WAV is.)
    private static func encodeAAC(_ composition: AVComposition, mix: AVAudioMix, to url: URL) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw AgentError("EXPORT_FAILED", "Cannot read the recording's audio.") }
        reader.add(output)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AgentError("EXPORT_FAILED", "Cannot encode the recording's audio.") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw AgentError("EXPORT_FAILED", (reader.error ?? writer.error)?.localizedDescription ?? "Audio mix could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "com.muckstack.myman.sharemix")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        guard reader.status != .failed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw AgentError("EXPORT_FAILED", (reader.error ?? writer.error)?.localizedDescription ?? "Audio mix failed.")
        }
    }
}
