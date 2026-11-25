import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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
final class ScreenEncoder {
    enum Failure: Error, Equatable { case writerFailed(String), notStarted, alreadyFinished }

    /// Audio that arrives before the first picture is kept (up to this many buffers) so its opening is not lost.
    static let maximumPendingAudio = 256

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let frameDuration: CMTime
    private let url: URL
    private var sessionStarted = false
    private var finished = false
    private var pendingAudio: [CMSampleBuffer] = []
    /// The most recent picture and its time, so a static screen can be held to the stop time.
    private var lastFrame: (image: CVPixelBuffer, time: CMTime)?

    init(url: URL, width: Int, height: Int, frameRate: Int, includesAudio: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        self.url = url
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
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

    /// Throws when the writer has failed for good (for example, the disk filled up). A rejected sample alone is not a failure.
    private func checkWriter() throws {
        if writer.status == .failed {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "the writer stopped")
        }
    }

    /// Returns false when this frame is skipped because the writer is busy. Skipping is preferable to blocking capture.
    @discardableResult
    func append(video buffer: CMSampleBuffer) throws -> Bool {
        guard !finished else { throw Failure.alreadyFinished }
        try checkWriter()
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !sessionStarted {
            // Start the session at the earlier of the first picture and the first held audio, so nothing is before it.
            var start = time
            if let firstAudio = pendingAudio.first {
                start = CMTimeMinimum(start, CMSampleBufferGetPresentationTimeStamp(firstAudio))
            }
            writer.startSession(atSourceTime: start)
            sessionStarted = true
            if let audio {
                for held in pendingAudio where audio.isReadyForMoreMediaData {
                    audio.append(held)
                }
            }
            pendingAudio = []
        }
        if let image = CMSampleBufferGetImageBuffer(buffer) {
            lastFrame = (image, time)
        }
        guard video.isReadyForMoreMediaData else { return false }
        return video.append(buffer)
    }

    @discardableResult
    func append(audio buffer: CMSampleBuffer) throws -> Bool {
        guard !finished else { throw Failure.alreadyFinished }
        try checkWriter()
        guard let audio else { return false }
        guard sessionStarted else {
            if pendingAudio.count < Self.maximumPendingAudio { pendingAudio.append(buffer) }
            return false
        }
        guard audio.isReadyForMoreMediaData else { return false }
        return audio.append(buffer)
    }

    /// Ends the segment at `endTime`, on the host clock that SCK timestamps use. A static screen sends no new frames,
    /// so the last picture is held until `endTime`. Without that, the file would end at the last change on screen.
    func finish(endingAt endTime: CMTime) async throws {
        guard !finished else { throw Failure.alreadyFinished }
        finished = true
        guard sessionStarted, let last = lastFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw Failure.notStarted
        }
        var sessionEnd = last.time + frameDuration
        if CMTimeCompare(endTime, sessionEnd) > 0 {
            // A repeat of the last picture at the stop time closes its duration. It is shown for one frame.
            let deadline = Date().addingTimeInterval(2)
            while !video.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if let hold = try Self.makeSample(image: last.image, time: endTime, frameDuration: frameDuration), video.isReadyForMoreMediaData {
                video.append(hold)
            }
            sessionEnd = endTime + frameDuration
        }
        writer.endSession(atSourceTime: sessionEnd)
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Abandons the segment and removes its file. Used when a recording fails to start.
    func cancel() {
        guard !finished else { return }
        finished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeSample(image: CVPixelBuffer, time: CMTime, frameDuration: CMTime) throws -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}

/// Receives an SCStream's screen and system-audio buffers and feeds one ScreenEncoder. All callbacks and the
/// encoder itself run on `queue`, so the encoder is never touched from two threads.
final class ScreenSegmentWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mm.screen.segment", qos: .userInitiated)
    private let encoder: ScreenEncoder
    private let lock = NSLock()
    private var firstFrameSeen = false
    private var failure: String?
    /// Called once, on the main actor, when capture or encoding fails mid-segment. The recorder stops the take.
    var onFailure: (@MainActor (String) -> Void)?

    init(url: URL, width: Int, height: Int, frameRate: Int, includesAudio: Bool) throws {
        encoder = try ScreenEncoder(url: url, width: width, height: height, frameRate: frameRate, includesAudio: includesAudio)
        super.init()
    }

    var hasFirstFrame: Bool { lock.withLock { firstFrameSeen } }
    var failureMessage: String? { lock.withLock { failure } }

    /// Waits until the first complete frame has been written, or throws after `timeout`.
    func waitForFirstFrame(timeout: TimeInterval) async throws {
        let limit = Date().addingTimeInterval(timeout)
        while !hasFirstFrame {
            if let failureMessage { throw AgentError("CAPTURE_FAILED", failureMessage) }
            guard Date() < limit else { throw AgentError("CAPTURE_TIMEOUT", "The screen did not send a frame. Check Screen Recording access.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Ends the segment at the current host time, after every buffer already delivered has been written.
    func finish() async throws {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                Task {
                    do {
                        try await self.encoder.finish(endingAt: now)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Abandons the segment and deletes its file. Safe to call after a failed start.
    func cancel() {
        queue.async { self.encoder.cancel() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // SCK also sends frames that carry no new picture (idle, blank, suspended). Only complete frames are encoded.
            guard Self.isComplete(sampleBuffer) else { return }
            do {
                if try encoder.append(video: sampleBuffer) { lock.withLock { firstFrameSeen = true } }
            } catch {
                fail(error.localizedDescription)
            }
        case .audio:
            do {
                try encoder.append(audio: sampleBuffer)
            } catch {
                fail(error.localizedDescription)
            }
        default:
            break
        }
    }

    /// The stream stopped on its own (display removed, permission revoked, and so on). The take must end.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        let first: Bool = lock.withLock {
            guard failure == nil else { return false }
            failure = message
            return true
        }
        guard first, let onFailure else { return }
        Task { @MainActor in onFailure(message) }
    }

    static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
