import AVFoundation
import Foundation

/// What an agent needs to judge a recording without downloading it: length, picture size, audio tracks,
/// size on disk, and where its frames fall. The file is written beside the recording as summary.json.
enum AgentRecordingSummary {
    static let maximumFrames = 60

    /// Frame times in seconds: one every `every` seconds, starting at 0, never more than `maximum` of them.
    static func frameTimes(duration: Double, every: Double = 10, maximum: Int = maximumFrames) -> [Double] {
        guard duration > 0, every > 0, maximum > 0 else { return [] }
        var times: [Double] = []
        var time = 0.0
        while time < duration, times.count < maximum { times.append(time); time += every }
        return times
    }

    static func summarize(_ url: URL, every: Double = 10) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AgentError("NOT_FOUND", "The recording has no readable length.") }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var width = 0, height = 0
        if let track = videoTracks.first {
            let size = try await track.load(.naturalSize)
            width = Int(size.width); height = Int(size.height)
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let frames = frameTimes(duration: duration, every: every).map { ["seconds": $0] as [String: Any] }
        return [
            "path": url.path,
            "duration_seconds": (duration * 100).rounded() / 100,
            "width": width, "height": height, "bytes": bytes,
            "audio_tracks": audioTracks.count,
            "frame_interval_seconds": every,
            "frames": frames,
            "frames_truncated": duration / every > Double(maximumFrames),
        ]
    }
}
