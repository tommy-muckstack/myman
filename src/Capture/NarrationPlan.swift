import Foundation

/// Numbers and decisions for a narration take: a face bubble and voice, no screen.
/// Kept apart from the recorder so the size cap and the reported fields can be tested without a camera.
enum NarrationPlan {
    static let width = 480
    static let height = 480
    static let videoBitrate = 450_000
    static let audioBitrate = 64_000
    /// The cap for a take that can be copied into an agent workspace.
    static let maximumBytes = 15_000_000
    /// Share of the cap a re-encode aims for, so container overhead cannot push it over.
    static let targetShare = 0.95
    static let minimumVideoBitrate = 120_000
    static let countdownSeconds = [3, 2, 1]
    static let maximumDurationSeconds = 300

    /// nil when the take already fits. Otherwise the video bitrate that should bring a take of this length under the cap.
    static func reencodeVideoBitrate(durationSeconds: Double, bytes: Int) -> Int? {
        guard bytes > maximumBytes, durationSeconds > 0 else { return nil }
        let budgetBitsPerSecond = Double(maximumBytes) * targetShare * 8 / durationSeconds
        return max(minimumVideoBitrate, Int(budgetBitsPerSecond) - audioBitrate)
    }

    /// The result an agent receives. startedAtEpochMs is the wall clock at the first video frame, in the same
    /// clock a browser reads with Date.now(), so a doc can line up its scroll log with the video.
    static func result(id: String, startedAtEpochMs: Int64, durationMs: Int, path: String, bytes: Int, reencodedVideoBitrate: Int?) -> [String: Any] {
        [
            "id": id,
            "startedAtEpochMs": startedAtEpochMs,
            "durationMs": durationMs,
            "path": path,
            "bytes": bytes,
            "mimeType": "video/mp4",
            "width": width,
            "height": height,
            "within_limit": bytes <= maximumBytes,
            "reencoded": reencodedVideoBitrate != nil,
            "video_bitrate": reencodedVideoBitrate ?? videoBitrate,
            "audio_bitrate": audioBitrate,
        ]
    }
}
