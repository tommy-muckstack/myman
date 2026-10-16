import AVFoundation

enum RecordingTranscriber {
    static func transcribe(_ url: URL) async throws -> [RecordingTranscript.Segment] {
        let source = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        await TranscriptionService.shared.parakeet.load()
        guard TranscriptionService.shared.parakeet.isReady else { throw PersonalizationError.invalid("The transcription model is not ready. Try again when its download finishes.") }
        let reader = try AVAssetReader(asset: asset)
        // Read all tracks on the same clock. Sequential track transcription
        // incorrectly placed system speech after the end of the microphone.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw PersonalizationError.invalid("This recording's audio cannot be read.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var buffer: [Float] = [], offset = 0.0, words: [RecordingTranscript.Segment] = []
        let chunk = 16000 * 25
        var first = true
        func drain(final: Bool) async throws {
            while buffer.count >= chunk + 32000 || (final && !buffer.isEmpty) {
                try Task.checkCancellation()
                let count = VoiceController.silenceAlignedEnd(samples: buffer, from: 0, chunkSamples: chunk)
                let samples = Array(buffer.prefix(count))
                buffer.removeFirst(count)
                if (samples.map(abs).max() ?? 0) > 0.003 {
                    words += await TranscriptionService.shared.parakeet.timedWords(samples, offset: offset)
                }
                offset += Double(count) / 16000
            }
        }
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if first { offset = max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds); first = false }
                if let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0, pointer: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                    if let pointer { pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { buffer.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) } }
                }
                try await drain(final: false)
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            try await drain(final: true)
            let current = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard source.fileSize == current.fileSize, source.contentModificationDate == current.contentModificationDate else {
                throw PersonalizationError.invalid("The recording changed during transcription. Generate the transcript again.")
            }
            try RecordingTranscript.save(words, for: url)
            return words
        } catch { reader.cancelReading(); throw error }
    }
}
