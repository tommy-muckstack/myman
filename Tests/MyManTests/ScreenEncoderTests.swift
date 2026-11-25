import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import MyMan

final class ScreenEncoderTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int, time: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, 200, CVPixelBufferGetBytesPerRow(pixels) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    func testBitrateScalesWithPixelRateAndStaysInBounds() {
        XCTAssertEqual(ScreenEncoderPlan.videoBitrate(width: 320, height: 200, frameRate: 30), ScreenEncoderPlan.minimumBitrate)
        XCTAssertEqual(ScreenEncoderPlan.videoBitrate(width: 5120, height: 2880, frameRate: 60), ScreenEncoderPlan.maximumBitrate)
        let hd30 = ScreenEncoderPlan.videoBitrate(width: 1920, height: 1080, frameRate: 30)
        XCTAssertEqual(hd30, Int(Double(1920 * 1080 * 30) * 0.11))
    }

    func testWritesAPlayableH264FileAtTheRequestedSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try ScreenEncoder(url: url, width: 640, height: 360, frameRate: 30, includesAudio: false)
        for frame in 0 ..< 60 {
            var accepted = false
            while !accepted {
                accepted = try encoder.append(video: makeBuffer(width: 640, height: 360, time: Double(frame) / 30))
                if !accepted { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        try await encoder.finish(endingAt: CMTime(seconds: 2, preferredTimescale: 600))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 640)
        XCTAssertEqual(Int(size.height), 360)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.2)
    }

    func testFinishingWithoutFramesFails() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try ScreenEncoder(url: url, width: 320, height: 200, frameRate: 30, includesAudio: false)
        do { try await encoder.finish(endingAt: CMTime(seconds: 1, preferredTimescale: 600)); XCTFail("expected notStarted") } catch {
            XCTAssertEqual(error as? ScreenEncoder.Failure, .notStarted)
        }
    }

    func testFramesWithoutACompleteStatusAreIgnored() throws {
        let buffer = try makeBuffer(width: 64, height: 64, time: 0)
        XCTAssertFalse(ScreenSegmentWriter.isComplete(buffer), "a buffer with no SCK status must not be encoded")
    }

    /// A screen that stops changing after two pictures still has its full length, to the stop time.
    func testStaticScreenIsHeldToTheStopTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try ScreenEncoder(url: url, width: 320, height: 200, frameRate: 30, includesAudio: false)
        try encoder.append(video: makeBuffer(width: 320, height: 200, time: 0))
        try encoder.append(video: makeBuffer(width: 320, height: 200, time: 1.0 / 30))
        try await encoder.finish(endingAt: CMTime(seconds: 2, preferredTimescale: 600))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.15, "the last picture must be held until the stop time")
    }

    /// A failed start leaves no file behind.
    func testCancelRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-\(UUID().uuidString).mp4")
        let encoder = try ScreenEncoder(url: url, width: 320, height: 200, frameRate: 30, includesAudio: false)
        encoder.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
