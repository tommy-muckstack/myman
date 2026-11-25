import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit

/// Numbers for a short looping clip: silent, small, and under the size cap for an inline doc image.
enum ClipPlan {
    static let maximumBytes = 4_000_000
    static let maximumEdge = 960
    static let fpsRange = 12 ... 15
    static let durationRange = 1 ... 20
    /// Share of the cap the bitrate is planned against, so container overhead stays under it.
    static let targetShare = 0.9
    static let maximumBitrate = 2_500_000

    static func fps(_ requested: Int?) throws -> Int {
        let value = requested ?? 15
        guard fpsRange.contains(value) else { throw AgentError("INVALID_ARGUMENTS", "fps must be 12 to 15.") }
        return value
    }

    static func duration(_ requested: Double?) throws -> Double {
        let value = requested ?? 20
        guard value >= 1, value <= 20 else { throw AgentError("INVALID_ARGUMENTS", "max_duration must be 1 to 20 seconds.") }
        return value
    }

    /// The video bitrate that keeps a clip of this length under the cap.
    static func videoBitrate(durationSeconds: Double) -> Int {
        let planned = Double(maximumBytes) * targetShare * 8 / durationSeconds
        return min(maximumBitrate, Int(planned))
    }

    /// Output width and height: the source aspect ratio, with the longer edge at most maximumEdge and both sides even.
    static func size(width: Double, height: Double) -> (Int, Int) {
        guard width > 0, height > 0 else { return (maximumEdge, maximumEdge) }
        let scale = min(1, Double(maximumEdge) / max(width, height))
        func even(_ value: Double) -> Int { max(2, Int((value * scale / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    static func result(id: String, path: String, posterPath: String?, bytes: Int, durationMs: Int, width: Int, height: Int, fps: Int) -> [String: Any] {
        [
            "id": id, "path": path, "poster_path": posterPath ?? NSNull(), "bytes": bytes, "mimeType": "video/mp4",
            "durationMs": durationMs, "width": width, "height": height, "fps": fps, "audio": false,
            "within_limit": bytes <= maximumBytes,
        ]
    }
}

/// Records one window or region for a short time, with no audio, and writes an mp4 plus a poster PNG.
/// Runs to completion inside one call, so it takes at most the clip's length plus setup.
@MainActor
enum ClipRecorder {
    static func record(windowID: String?, region: CGRect?, maxDuration: Double, fps: Int) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { throw AgentError("PERMISSION_REQUIRED", "Allow Screen Recording for My Man in Privacy, then try again.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let width: Double, height: Double
        if let windowID {
            guard let window = content.windows.first(where: { String($0.windowID) == windowID }) else {
                throw AgentError("NOT_FOUND", "No window with id \(windowID) is on screen. Run screenshot.targets to see ids.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            width = window.frame.width; height = window.frame.height
        } else {
            guard let region, let display = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(region) }) else {
                throw AgentError("INVALID_ARGUMENTS", "Give window_id, or a region on a connected display.")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = region.width; height = region.height
        }
        let (outWidth, outHeight) = ClipPlan.size(width: width, height: height)
        let configuration = SCStreamConfiguration()
        configuration.width = outWidth; configuration.height = outHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        if let region { configuration.sourceRect = region }

        let id = UUID().uuidString
        let folder = try destination()
        let movie = folder.appendingPathComponent(id + ".mp4")
        let sink = try ClipSink(url: movie, width: outWidth, height: outHeight, bitrate: ClipPlan.videoBitrate(durationSeconds: maxDuration))
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(maxDuration))
        try await stream.stopCapture()
        let durationMs = Int(maxDuration * 1000)
        let poster = try await sink.finish(posterURL: folder.appendingPathComponent(id + "-poster.png"))
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: movie.path)[.size]) as? NSNumber)?.intValue ?? 0
        var result = ClipPlan.result(id: id, path: movie.path, posterPath: poster?.path, bytes: bytes, durationMs: durationMs, width: outWidth, height: outHeight, fps: fps)
        let resultURL = try AgentDelivery.writeResult(result, id: id, folder: folder)
        result["result_path"] = resultURL.path
        var paths = ["video": movie.path, "result": resultURL.path]
        if let poster { paths["poster"] = poster.path }
        try? AgentChangeLog.append(kind: "clip", id: id, paths: paths, at: AgentActions.date(Date()))
        return result
    }

    private static func destination() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("MyMan/Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Writes frames to the mp4 on one serial queue. Keeps the first complete frame for the poster.
final class ClipSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "mm.clip.write")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var origin: CMTime?
    private var poster: CVPixelBuffer?

    init(url: URL, width: Int, height: Int, bitrate: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if origin == nil {
            origin = time
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            poster = pixels
        }
        guard let origin, input.isReadyForMoreMediaData else { return }
        adaptor.append(pixels, withPresentationTime: CMTimeSubtract(time, origin))
    }

    /// Ends the file and writes the poster PNG from the first frame. Returns nil if no frame arrived.
    func finish(posterURL: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            queue.async {
                guard self.origin != nil else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: AgentError("CAPTURE_FAILED", "No frames arrived. Check Screen Recording access."))
                    return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    guard self.writer.status == .completed else {
                        continuation.resume(throwing: AgentError("CAPTURE_FAILED", self.writer.error?.localizedDescription ?? "The clip could not be finished."))
                        return
                    }
                    guard let poster = self.poster else { continuation.resume(returning: nil); return }
                    let image = CIImage(cvPixelBuffer: poster)
                    let context = CIContext()
                    guard let png = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
                        continuation.resume(returning: nil); return
                    }
                    do { try png.write(to: posterURL); continuation.resume(returning: posterURL) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
