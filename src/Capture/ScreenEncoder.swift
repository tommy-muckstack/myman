import AVFoundation
import CoreMedia
import ScreenCaptureKit
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

/// Receives an SCStream's screen and system-audio buffers and feeds one ScreenEncoder. All callbacks and the
/// encoder itself run on `queue`, so the encoder is never touched from two threads.
final class ScreenSegmentWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "mm.screen.segment", qos: .userInitiated)
    private let encoder: ScreenEncoder
    private let lock = NSLock()
    private var firstFrameSeen = false
    private var failure: String?
    /// Called once, on the main actor, when the encoder fails mid-segment. The recorder stops the take.
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

    /// Ends the segment after every buffer already delivered has been written.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                Task {
                    do {
                        try await self.encoder.finish()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
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
