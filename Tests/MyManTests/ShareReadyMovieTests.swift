import AVFoundation
import XCTest
@testable import MyMan

/// The saved recording must be the one shape every player decodes: an .mp4
/// with one H.264 video track and one AAC audio track that already carries
/// the narration. (A second audio track is silently dropped by browsers and
/// Slack — the "my recording has no sound" bug.)
final class ShareReadyMovieTests: XCTestCase {
    @MainActor func testNarrationAndSystemAudioBecomeOneAACTrackInAnMP4() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("take.mov")
        try await fixtureMovie(movie, seconds: 2, systemTone: 440)
        let wav = folder.appendingPathComponent("take.narration.wav")
        try fixtureWav(wav, seconds: 1, tone: 1000)

        let output = try await ShareReadyMovie.finalize(movie: movie, narration: wav, narrationOffsetSeconds: 0.5)
        XCTAssertEqual(output.pathExtension, "mp4")
        XCTAssertEqual(output.deletingPathExtension().lastPathComponent, "take")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path), "inputs are the caller's to delete")

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1, "exactly one audio track — the mixed one")
        let descriptions = try await audio[0].load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kAudioFormatMPEG4AAC)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)

        // The narration is audible where it was inserted (0.5–1.5s) and the
        // system tone is still there around it.
        let energy = try await ShareReadyMovieTests.bandEnergy(output, from: 0.6, to: 1.4)
        XCTAssertGreaterThan(energy.narration, energy.noiseFloor * 20, "1 kHz narration tone present in the mixed track")
        XCTAssertGreaterThan(energy.system, energy.noiseFloor * 20, "440 Hz system tone survives the mix")
        let tail = try await ShareReadyMovieTests.bandEnergy(output, from: 1.6, to: 1.95)
        XCTAssertLessThan(tail.narration, tail.system / 4, "no narration after the WAV ends")
    }

    @MainActor func testVideoOnlyCaptureStillBecomesAnMP4() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-share-silent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("silent.mov")
        try await fixtureMovie(movie, seconds: 1, systemTone: nil)
        let output = try await ShareReadyMovie.finalize(movie: movie, narration: nil)
        let asset = AVURLAsset(url: output)
        let videoCount = try await asset.loadTracks(withMediaType: .video).count
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(videoCount, 1)
        XCTAssertEqual(audioCount, 0)
        XCTAssertEqual(output.pathExtension, "mp4")
    }

    @MainActor func testWorkspaceExportsCutsRedactionAndCaptionTitleOffsetWithoutChangingOriginal() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("synthetic.mov"), output = folder.appendingPathComponent("edited.mp4")
        try await fixtureMovie(source, seconds: 4, systemTone: 440)
        let fingerprint = try SharePublishing.fileFingerprint(source)
        let words: [RecordingTranscript.Segment] = [.init(start: 0, end: 0.4, text: "First."), .init(start: 3, end: 3.5, text: "Last.")]
        try RecordingTranscript.save(words, for: source)
        var project = RecordingProject(edits: .init(cuts: [.init(start: 0.5, end: 1), .init(start: 2, end: 2.5)]), captions: words, title: "Synthetic demo")
        project.overlays = [.init(kind: "redact", start: 0, end: 4, x: 80, y: 40, width: 120, height: 80)]
        var options = PolishOptions(); options.backdrop = .none; options.zoomOnClicks = false; options.motionBlur = false
        try await RecordingWorkspaceExport.export(source: source, destination: output, project: project, options: options) { _ in }
        XCTAssertEqual(try SharePublishing.fileFingerprint(source), fingerprint)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.16)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(audioCount, 1)
        let transcript = try XCTUnwrap(RecordingTranscript.load(for: output))
        XCTAssertEqual(transcript.segments.map(\.start), [3, 5])
        let saved = try XCTUnwrap(RecordingProject.load(for: source))
        XCTAssertEqual(saved.edits, project.edits)
        XCTAssertEqual(saved.polish?.backdrop, BackdropStyle.none.rawValue)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        // The default infinite tolerance can return a title-card keyframe.
        // Inspect exact content frames on both sides of the removed ranges.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for seconds in [3.2, 5.2] {
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            XCTAssertEqual(frame.actualTime.seconds, seconds, accuracy: 0.05)
            XCTAssertEqual(frame.image.width, 320)
            XCTAssertEqual(frame.image.height, 200)
            let image = NSBitmapImageRep(cgImage: frame.image)
            let redacted = try XCTUnwrap(image.colorAt(x: 140, y: 80)?.usingColorSpace(.deviceRGB))
            let visible = try XCTUnwrap(image.colorAt(x: 260, y: 150)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(redacted.redComponent + redacted.greenComponent + redacted.blueComponent, 0.15)
            XCTAssertGreaterThan(visible.blueComponent, 0.6, "unredacted blue fixture remains visible at \(seconds)s")
        }
    }

    // MARK: Fixtures

    /// H.264 video with an optional AAC system-audio sine (what SCK hands us).
    @MainActor private func fixtureMovie(_ url: URL, seconds: Double, systemTone: Double?) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(video)
        var audio: AVAssetWriterInput?
        if systemTone != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            writer.add(input); audio = input
        }
        guard writer.startWriting() else { throw writer.error ?? AgentError("TEST_WRITER", "Synthetic video writer could not start") }; writer.startSession(atSourceTime: .zero)
        // Audio goes in FIRST: the writer interleaves tracks and holds the
        // video input "not ready" until audio for the same span exists.
        if let audio, let tone = systemTone {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let count = AVAudioFrameCount(48_000 * seconds)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            pcm.frameLength = count
            for channel in 0..<2 {
                let samples = pcm.floatChannelData![channel]
                for i in 0..<Int(count) { samples[i] = 0.4 * sin(Float(i) * Float(2 * Double.pi * tone / 48_000)) }
            }
            var formatDescription: CMAudioFormatDescription?
            var asbd = format.streamDescription.pointee
            XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription), noErr)
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription, sampleCount: CMItemCount(count), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), noErr)
            try await waitReady(audio)
            XCTAssertTrue(audio.append(buffer))
            audio.markAsFinished()
        }
        let frames = Int(seconds * 10)
        for index in 0..<frames {
            try await waitReady(video)
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &value), kCVReturnSuccess)
            let buffer = try XCTUnwrap(value); CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        video.markAsFinished()
        await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }

    private func waitReady(_ input: AVAssetWriterInput) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard Date() < deadline else { throw AgentError("TEST_TIMEOUT", "Writer input never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Mono 16-bit WAV at the mic's native rate — what NarrationTrack writes.
    private func fixtureWav(_ url: URL, seconds: Double, tone: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let count = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.int16ChannelData![0]
        for i in 0..<Int(count) { samples[i] = Int16(20_000 * sin(Double(i) * 2 * Double.pi * tone / 48_000)) }
        try file.write(from: buffer)
    }

    /// Goertzel energy at the narration tone (1 kHz), the system tone
    /// (440 Hz) and an empty band (3 kHz) over a slice of the mixed track.
    private static func bandEnergy(_ url: URL, from: Double, to: Double) async throws -> (narration: Double, system: Double, noiseFloor: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer { pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) } }
        }
        func goertzel(_ hz: Double) -> Double {
            let k = 2 * cos(2 * Double.pi * hz / 48_000)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            for x in samples { s0 = Double(x) + k * s1 - s2; s2 = s1; s1 = s0 }
            return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(max(1, samples.count))
        }
        return (goertzel(1000), goertzel(440), max(1e-9, goertzel(3000)))
    }
}
