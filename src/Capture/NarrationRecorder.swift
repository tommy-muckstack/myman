import AVFoundation
import Foundation

/// Narration: the front camera and the microphone, written straight to an mp4. No screen is captured.
/// The clock that matters is the first video frame's wall-clock time, which goes in startedAtEpochMs.
/// Writing happens on one serial queue owned by NarrationSink, so no AVFoundation object is shared across threads.
@MainActor
final class NarrationRecorder: ObservableObject {
    static let shared = NarrationRecorder()

    enum Phase: Equatable { case idle, countingDown(Int), recording, finishing }
    @Published private(set) var phase: Phase = .idle {
        didSet { NotificationCenter.default.post(name: .narrationPhaseChanged, object: nil) }
    }
    private(set) var sessionID: String?

    private var session: AVCaptureSession?
    private var sink: NarrationSink?
    private var outputURL: URL?
    private var cancelled = false
    private var autoStop: Task<Void, Never>?
    private var label: String?

    var isActive: Bool { phase != .idle }
    /// True while the camera and microphone are running. The menu bar shows a red dot for this.
    var isCapturing: Bool { phase == .recording || phase == .finishing }

    /// Starts after a 3-2-1 countdown, so the person can switch to the page they are narrating.
    /// Returns once the camera and microphone are running and the first frame has arrived.
    func start(label: String? = nil) async throws -> String {
        guard phase == .idle else { throw AgentError("BUSY", "A narration is already running. Stop it first.") }
        if let label, !AgentDelivery.isValidLabel(label) { throw AgentError("INVALID_ARGUMENTS", "label takes letters, numbers, dots, dashes and underscores, up to 80 characters. Use the doc section id.") }
        self.label = label
        try await ensureDevicesAllowed()
        cancelled = false
        for count in NarrationPlan.countdownSeconds {
            phase = .countingDown(count)
            try await Task.sleep(for: .seconds(1))
            if cancelled { phase = .idle; throw AgentError("CANCELLED", "Narration was stopped before it started.") }
        }
        let id = UUID().uuidString
        let url = try Self.destination(id: id)
        let sink = try NarrationSink(url: url)
        let capture = try Self.makeSession(sink: sink)
        self.sink = sink; self.session = capture; self.outputURL = url; self.sessionID = id
        capture.startRunning()
        NarrationBubble.show(session: capture)
        phase = .recording
        // Wait for the first video frame so the start time is real before anything returns.
        for _ in 0 ..< 200 where sink.startedAtEpochMs == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard sink.startedAtEpochMs != nil else { _ = try? await stop(); throw AgentError("CAPTURE_FAILED", "The camera did not send a frame. Check Camera access in Privacy.") }
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NarrationPlan.maximumDurationSeconds))
            guard let self, self.phase == .recording else { return }
            _ = try? await self.stop()
        }
        return id
    }

    /// Stops and finalizes. Re-encodes at a lower bitrate if the take is over the cap, then reports the final size.
    func stop() async throws -> [String: Any] {
        guard let sink, let capture = session, let url = outputURL, let id = sessionID else {
            NarrationBubble.close()
            if case .countingDown = phase { cancelled = true }
            throw AgentError("NOT_RECORDING", "No narration is running.")
        }
        autoStop?.cancel(); autoStop = nil
        NarrationBubble.close()
        phase = .finishing
        let startedAt = sink.startedAtEpochMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        // Stop the devices off the main thread; stopRunning blocks.
        await Task.detached(priority: .userInitiated) { capture.stopRunning() }.value
        try await sink.finish()
        let durationMs = Int(Int64(Date().timeIntervalSince1970 * 1000) - startedAt)
        var bytes = Self.size(of: url)
        var reencoded: Int?
        if let bitrate = NarrationPlan.reencodeVideoBitrate(durationSeconds: Double(durationMs) / 1000, bytes: bytes) {
            let smaller = url.deletingLastPathComponent().appendingPathComponent(id + ".small.mp4")
            try await NarrationReencoder.reencode(source: url, destination: smaller, videoBitrate: bitrate)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: smaller, to: url)
            bytes = Self.size(of: url)
            reencoded = bitrate
        }
        session = nil; self.sink = nil; outputURL = nil; sessionID = nil
        phase = .idle
        var result = NarrationPlan.result(id: id, startedAtEpochMs: startedAt, durationMs: durationMs, path: url.path, bytes: bytes, reencodedVideoBitrate: reencoded)
        result["label"] = label ?? NSNull()
        let resultURL = try AgentDelivery.writeResult(result, id: id, folder: url.deletingLastPathComponent())
        result["result_path"] = resultURL.path
        try? AgentChangeLog.append(kind: "narration", id: id, paths: ["video": url.path, "result": resultURL.path], at: AgentActions.date(Date()))
        label = nil
        return result
    }

    /// Used by Pause everything and when quitting. Ends a take in progress, and cancels one still counting down.
    func emergencyStop() {
        if case .countingDown = phase { cancelled = true; return }
        guard phase == .recording || phase == .finishing else { return }
        Task { _ = try? await self.stop() }
    }

    // MARK: Agent entry points

    func startForAgent(label: String? = nil) async throws -> [String: Any] {
        let id = try await start(label: label)
        return ["id": id, "started": true, "countdown_seconds": NarrationPlan.countdownSeconds, "max_duration_seconds": NarrationPlan.maximumDurationSeconds]
    }

    func stopForAgent() async throws -> [String: Any] { try await stop() }

    func statusForAgent() -> [String: Any] {
        var status: [String: Any] = ["phase": String(describing: phase), "session_id": sessionID ?? NSNull()]
        if case .countingDown(let count) = phase { status["countdown"] = count }
        return status
    }

    // MARK: Setup

    private func ensureDevicesAllowed() async throws {
        for type in [AVMediaType.video, AVMediaType.audio] {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: continue
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: type) else { throw Self.permissionError(type) }
            default: throw Self.permissionError(type)
            }
        }
    }

    private static func permissionError(_ type: AVMediaType) -> AgentError {
        let device = type == .video ? "Camera" : "Microphone"
        return AgentError("PERMISSION_REQUIRED", "Allow \(device) for My Man in Privacy, then try again.")
    }

    private static func makeSession(sink: NarrationSink) throws -> AVCaptureSession {
        let capture = AVCaptureSession()
        capture.sessionPreset = .vga640x480
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let microphone = AVCaptureDevice.default(for: .audio) else {
            throw AgentError("DEVICE_UNAVAILABLE", "No front camera or microphone is available on this Mac.")
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard capture.canAddInput(cameraInput), capture.canAddInput(microphoneInput) else {
            throw AgentError("DEVICE_UNAVAILABLE", "The camera or microphone could not be added.")
        }
        capture.addInput(cameraInput); capture.addInput(microphoneInput)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(sink, queue: sink.queue)
        let audio = AVCaptureAudioDataOutput()
        audio.setSampleBufferDelegate(sink, queue: sink.queue)
        guard capture.canAddOutput(video), capture.canAddOutput(audio) else { throw AgentError("DEVICE_UNAVAILABLE", "Narration outputs could not be added.") }
        capture.addOutput(video); capture.addOutput(audio)
        return capture
    }

    private static func destination(id: String) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("MyMan/Narrations", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(id + ".mp4")
    }

    private static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}

extension Notification.Name {
    static let narrationPhaseChanged = Notification.Name("mm.narrationPhaseChanged")
}

/// Owns the writer. Every callback and every write runs on `queue`.
final class NarrationSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mm.narration.write")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private var started = false
    private(set) var startedAtEpochMs: Int64?

    init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NarrationPlan.width,
            AVVideoHeightKey: NarrationPlan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: NarrationPlan.videoBitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel],
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100, AVEncoderBitRateKey: NarrationPlan.audioBitrate,
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video); writer.add(audio)
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if output is AVCaptureVideoDataOutput {
            if !started {
                // The first video frame sets the clock: the wall time now, and the source time the file starts at.
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                started = true
                startedAtEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
            if video.isReadyForMoreMediaData { video.append(sampleBuffer) }
        } else if started, audio.isReadyForMoreMediaData {
            audio.append(sampleBuffer)
        }
    }

    /// Ends the file. Runs on the write queue, so no sample can arrive after it.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.started else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: AgentError("CAPTURE_FAILED", "No video frames were recorded."))
                    return
                }
                self.video.markAsFinished(); self.audio.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: AgentError("CAPTURE_FAILED", self.writer.error?.localizedDescription ?? "The narration file could not be finished.")) }
                }
            }
        }
    }
}

/// Re-encodes a finished take at a lower video bitrate, keeping the audio as it is.
enum NarrationReencoder {
    static func reencode(source: URL, destination: URL, videoBitrate: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AgentError("CAPTURE_FAILED", "The narration file has no video or audio to re-encode.")
        }
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(videoOut); reader.add(audioOut)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: NarrationPlan.width, AVVideoHeightKey: NarrationPlan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel],
        ])
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        videoIn.expectsMediaDataInRealTime = false; audioIn.expectsMediaDataInRealTime = false
        writer.add(videoIn); writer.add(audioIn)
        guard reader.startReading() else { throw AgentError("CAPTURE_FAILED", "The narration file could not be read again.") }
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "mm.narration.reencode.video"), audioQueue = DispatchQueue(label: "mm.narration.reencode.audio")
        pump(videoOut, videoIn, on: videoQueue, group: group)
        pump(audioOut, audioIn, on: audioQueue, group: group)
        await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else {
            throw AgentError("CAPTURE_FAILED", "The narration file could not be re-encoded. The original is kept.")
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, on queue: DispatchQueue, group: DispatchGroup) {
        group.enter()
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    input.append(sample)
                } else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }
}
