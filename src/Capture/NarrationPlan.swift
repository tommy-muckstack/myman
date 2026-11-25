import Foundation

/// Numbers and decisions for a narration take: a face bubble and voice, no screen.
/// Kept apart from the recorder so the size cap and the reported fields can be tested without a camera.
enum NarrationPlan {
    /// Which camera preset to ask for. The output is square, cropped from the camera frame.
    /// `highest` picks the camera's largest format that can run at 30 fps, so an external camera's full sensor is used.
    enum CameraQuality: Equatable { case vga640x480, hd1280x720, highest }

    struct Profile: Equatable {
        let width: Int
        let height: Int
        let videoBitrate: Int
        let audioBitrate: Int
        let camera: CameraQuality
        /// nil means no size cap. Only takes that go to an agent workspace have one.
        let maximumBytes: Int?
    }

    /// Largest square output side. A 4K sensor's full height, which H.264 level 5.1 can carry.
    static let maximumSide = 2160
    static let maximumPersonalBitrate = 24_000_000

    /// For `.highest`, the output is the square side of the camera's sensor (capped at 2160), and the video
    /// bitrate scales with pixel count from the base profile, up to a ceiling. Other profiles pass through unchanged.
    static func squareProfile(from base: Profile, sensorWidth: Int, sensorHeight: Int) -> Profile {
        guard base.camera == .highest, sensorWidth > 0, sensorHeight > 0 else { return base }
        let side = min(min(sensorWidth, sensorHeight), maximumSide) & ~1
        let scale = Double(side * side) / Double(base.width * base.height)
        let scaled = Int(Double(base.videoBitrate) * scale)
        let bitrate = min(maximumPersonalBitrate, max(base.videoBitrate, scaled))
        return Profile(width: side, height: side, videoBitrate: bitrate, audioBitrate: base.audioBitrate,
                       camera: base.camera, maximumBytes: base.maximumBytes)
    }

    /// Your own recordings, started from the hotkey or menu bar. The camera's highest format, 1080x1080 output, no size cap.
    static let personal = Profile(width: 1080, height: 1080, videoBitrate: 8_000_000, audioBitrate: 128_000,
                                  camera: .highest, maximumBytes: nil)
    /// Takes an agent starts. Small enough to copy into an agent workspace (15 MB).
    static let agent = Profile(width: 480, height: 480, videoBitrate: 450_000, audioBitrate: 64_000,
                               camera: .vga640x480, maximumBytes: 15_000_000)

    static let width = agent.width
    static let height = agent.height
    static let videoBitrate = agent.videoBitrate
    static let audioBitrate = agent.audioBitrate
    /// The cap for a take that can be copied into an agent workspace.
    static let maximumBytes = agent.maximumBytes ?? 15_000_000
    /// Share of the cap a re-encode aims for, so container overhead cannot push it over.
    static let targetShare = 0.95
    static let minimumVideoBitrate = 120_000
    static let countdownSeconds = [3, 2, 1]
    static let maximumDurationSeconds = 300

    /// nil when the take already fits. Otherwise the video bitrate that should bring a take of this length under the cap.
    static func reencodeVideoBitrate(durationSeconds: Double, bytes: Int, profile: Profile = agent) -> Int? {
        guard let cap = profile.maximumBytes, bytes > cap, durationSeconds > 0 else { return nil }
        let budgetBitsPerSecond = Double(cap) * targetShare * 8 / durationSeconds
        return max(minimumVideoBitrate, Int(budgetBitsPerSecond) - profile.audioBitrate)
    }

    /// The result an agent receives. startedAtEpochMs is the wall clock at the first video frame, in the same
    /// clock a browser reads with Date.now(), so a doc can line up its scroll log with the video.
    static func result(id: String, startedAtEpochMs: Int64, durationMs: Int, path: String, bytes: Int, reencodedVideoBitrate: Int?, profile: Profile = agent) -> [String: Any] {
        [
            "id": id,
            "startedAtEpochMs": startedAtEpochMs,
            "durationMs": durationMs,
            "path": path,
            "bytes": bytes,
            "mimeType": "video/mp4",
            "width": profile.width,
            "height": profile.height,
            "within_limit": bytes <= (profile.maximumBytes ?? Int.max),
            "reencoded": reencodedVideoBitrate != nil,
            "video_bitrate": reencodedVideoBitrate ?? profile.videoBitrate,
            "audio_bitrate": profile.audioBitrate,
        ]
    }
}
