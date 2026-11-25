import AVFoundation
import CoreMedia
import Foundation

/// Bitrate for a screen recording, from its pixel rate. Screen content is sharp text on flat color, so the rate
/// is set per pixel per frame, not from a fixed table. Clamped so small windows don't starve and 5K doesn't balloon.
enum ScreenEncoderPlan {
    static let bitsPerPixel = 0.11
    static let minimumBitrate = 6_000_000
    static let maximumBitrate = 40_000_000
    static let audioBitrate = 192_000

    static func videoBitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let raw = Double(width * height * frameRate) * bitsPerPixel
        return min(maximumBitrate, max(minimumBitrate, Int(raw)))
    }
}

/// Writes one H.264 (High profile) mp4 from captured screen frames and optional system audio.
/// One writer per segment, so pause and resume keep working by finishing the segment and starting another.
/// Not wired into ScreenRecorder yet; see the screen-encoder PR notes.
final class ScreenEncoder {
    enum Failure: Error, Equatable { case writerFailed(String), notStarted, alreadyFinished }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false

    init(url: URL, width: Int, height: Int, frameRate: Int, includesAudio: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: ScreenEncoderPlan.videoBitrate(width: width, height: height, frameRate: frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if includesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: ScreenEncoderPlan.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
        guard writer.startWriting() else { throw Failure.writerFailed(writer.error?.localizedDescription ?? "unknown") }
    }

    /// Returns false when the frame is dropped (the writer is not ready). Dropping is preferable to blocking capture.
    @discardableResult
    func append(video buffer: CMSampleBuffer) throws -> Bool {
        guard !finished else { throw Failure.alreadyFinished }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            sessionStarted = true
        }
        guard video.isReadyForMoreMediaData else { return false }
        return video.append(buffer)
    }

    @discardableResult
    func append(audio buffer: CMSampleBuffer) throws -> Bool {
        guard !finished else { throw Failure.alreadyFinished }
        guard sessionStarted, let audio else { return false }
        guard audio.isReadyForMoreMediaData else { return false }
        return audio.append(buffer)
    }

    /// Ends the segment and closes the file. Call once.
    func finish() async throws {
        guard !finished else { throw Failure.alreadyFinished }
        finished = true
        guard sessionStarted else {
            writer.cancelWriting()
            throw Failure.notStarted
        }
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}
