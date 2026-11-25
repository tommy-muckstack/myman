import AVFoundation
import CryptoKit
import Foundation

/// Narration: the front camera and the microphone, written straight to an mp4. No screen is captured.
/// The clock that matters is the first video frame's wall-clock time, which goes in startedAtEpochMs.
/// Writing happens on one serial queue owned by NarrationSink, so no AVFoundation object is shared across threads.
@MainActor
final class NarrationRecorder: ObservableObject {
    static let shared = NarrationRecorder()

    enum Phase: Equatable { case idle, countingDown(Int), recording, paused, finishing }
    @Published private(set) var phase: Phase = .idle {
        didSet { NotificationCenter.default.post(name: .narrationPhaseChanged, object: nil) }
    }
    private(set) var sessionID: String?
    /// Recorded time so far, without paused time. Refreshed about four times a second while a take runs.
    @Published private(set) var elapsedMs = 0

    private var session: AVCaptureSession?
    private var sink: NarrationSink?
    private var outputURL: URL?
    private var cancelled = false
    private var autoStop: Task<Void, Never>?
    private var label: String?
    private var profile: NarrationPlan.Profile = NarrationPlan.personal
    /// Takes stopped in this session. Only these can be read or discarded through the agent, so no other file is reachable.
    private var finishedIDs: [String] = []
    static let chunkBytes = 256 * 1024

    var isActive: Bool { phase != .idle }
    /// True while the camera and microphone are running. The menu bar shows a red dot for this.
    var isCapturing: Bool { phase == .recording || phase == .paused || phase == .finishing }

    /// Starts after a 3-2-1 countdown, so the person can switch to the page they are narrating.
    /// Returns once the camera and microphone are running and the first frame has arrived.
    func start(label: String? = nil, profile: NarrationPlan.Profile = NarrationPlan.personal) async throws -> String {
        guard phase == .idle else { throw AgentError("BUSY", "A narration is already running. Stop it first.") }
        NarrationControlPanel.show(recorder: self)
        do {
            return try await beginTake(label: label, profile: profile)
        } catch {
            NarrationControlPanel.close()
            throw error
        }
    }

    private func beginTake(label: String?, profile: NarrationPlan.Profile) async throws -> String {
        self.profile = profile
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
        // The camera decides the output size for personal recordings, so resolve it before the writer is built.
        let effective = try Self.resolvedProfile(profile)
        self.profile = effective
        let sink = try NarrationSink(url: url, profile: effective)
        let capture = try Self.makeSession(sink: sink, profile: effective)
        self.sink = sink; self.session = capture; self.outputURL = url; self.sessionID = id
        capture.startRunning()
        NarrationBubble.show(session: capture)
        phase = .recording
        // Wait for the first video frame so the start time is real before anything returns.
        for _ in 0 ..< 200 where sink.startedAtEpochMs == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard sink.startedAtEpochMs != nil else { _ = try? await stop(); throw AgentError("CAPTURE_FAILED", "The camera did not send a frame. Check Camera access in Privacy.") }
        startTicker()
        return id
    }

    /// Keeps elapsed time for the panel, and ends the take at the cap. The cap counts recorded time, so a pause does not use it up.
    private func startTicker() {
        autoStop?.cancel()
        autoStop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .recording || self.phase == .paused, let sink = self.sink else { return }
                let ms = sink.recordedMs
                self.elapsedMs = ms
                if ms >= NarrationPlan.maximumDurationSeconds * 1000 {
                    // Its own task, so the stop is not cancelled along with this loop.
                    Task { _ = try? await self.stop() }
                    return
                }
            }
        }
    }

    /// Pauses the take. Nothing is written while paused, and the paused time is not counted in the length.
    func pause() throws {
        guard phase == .recording, let sink else { throw AgentError("NOT_RECORDING", "No narration is recording, so there is nothing to pause.") }
        sink.setPaused(true)
        phase = .paused
    }

    func resume() throws {
        guard phase == .paused, let sink else { throw AgentError("NOT_PAUSED", "The narration is not paused.") }
        sink.setPaused(false)
        phase = .recording
    }

    /// Throws away the take and counts down again. Keeps the label. The panel asks first when the take is longer than 5 seconds.
    func restart() async throws -> String {
        guard phase == .recording || phase == .paused else { throw AgentError("NOT_RECORDING", "No narration is recording, so there is nothing to restart.") }
        let keep = label
        await discard()
        return try await start(label: keep, profile: profile)
    }

    /// Throws away the take and its file. The label is kept here; cancelTake clears it.
    func discard() async {
        if case .countingDown = phase { cancelled = true; NarrationControlPanel.close(); return }
        autoStop?.cancel(); autoStop = nil
        NarrationBubble.close()
        guard let sink, let capture = session, let url = outputURL else {
            NarrationControlPanel.close()
            phase = .idle
            return
        }
        phase = .finishing
        await Task.detached(priority: .userInitiated) { capture.stopRunning() }.value
        await sink.discard(url: url)
        session = nil; self.sink = nil; outputURL = nil; sessionID = nil
        elapsedMs = 0
        phase = .idle
        NarrationControlPanel.close()
    }

    /// Discards the take for good, and clears its label.
    func cancelTake() async {
        label = nil
        await discard()
    }

    /// Stops and finalizes. Re-encodes at a lower bitrate if the take is over the cap, then reports the final size.
    func stop() async throws -> [String: Any] {
        guard let sink, let capture = session, let url = outputURL, let id = sessionID else {
            NarrationBubble.close()
            NarrationControlPanel.close()
            if case .countingDown = phase { cancelled = true }
            throw AgentError("NOT_RECORDING", "No narration is running.")
        }
        autoStop?.cancel(); autoStop = nil
        NarrationBubble.close()
        NarrationControlPanel.close()
        phase = .finishing
        let startedAt = sink.startedAtEpochMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        // Stop the devices off the main thread; stopRunning blocks.
        await Task.detached(priority: .userInitiated) { capture.stopRunning() }.value
        try await sink.finish()
        // The length is the recorded time, so a pause does not count toward it.
        let durationMs = sink.recordedMs
        elapsedMs = durationMs
        var bytes = Self.size(of: url)
        var reencoded: Int?
        if let bitrate = NarrationPlan.reencodeVideoBitrate(durationSeconds: Double(durationMs) / 1000, bytes: bytes, profile: profile) {
            let smaller = url.deletingLastPathComponent().appendingPathComponent(id + ".small.mp4")
            try await NarrationReencoder.reencode(source: url, destination: smaller, videoBitrate: bitrate)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: smaller, to: url)
            bytes = Self.size(of: url)
            reencoded = bitrate
        }
        session = nil; self.sink = nil; outputURL = nil; sessionID = nil
        phase = .idle
        var result = NarrationPlan.result(id: id, startedAtEpochMs: startedAt, durationMs: durationMs, path: url.path, bytes: bytes, reencodedVideoBitrate: reencoded, profile: profile)
        result["label"] = label ?? NSNull()
        // The digest and chunk count let a reader check the transfer without trusting it.
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        result["sha256"] = digest
        result["chunkBytes"] = Self.chunkBytes
        result["chunkCount"] = max(1, (bytes + Self.chunkBytes - 1) / Self.chunkBytes)
        finishedIDs.append(id)
        if finishedIDs.count > 5 { finishedIDs.removeFirst() }
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
        let id = try await start(label: label, profile: NarrationPlan.agent)
        return ["id": id, "started": true, "startedAtEpochMs": sink?.startedAtEpochMs ?? NSNull(),
                "countdown_seconds": NarrationPlan.countdownSeconds, "max_duration_seconds": NarrationPlan.maximumDurationSeconds]
    }

    /// One 256 KB piece of a take that was just stopped. Base64 keeps each tool result small.
    func chunkForAgent(id: String, index: Int) throws -> [String: Any] {
        let url = try readableFile(id: id)
        let size = Self.size(of: url)
        let count = max(1, (size + Self.chunkBytes - 1) / Self.chunkBytes)
        guard index >= 0, index < count else { throw AgentError("INVALID_ARGUMENTS", "index must be from 0 to \(count - 1) for this take.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * Self.chunkBytes))
        let data = try handle.read(upToCount: Self.chunkBytes) ?? Data()
        return ["index": index, "chunkCount": count, "base64": data.base64EncodedString()]
    }

    /// Deletes a take that was just stopped. Takes outside this session cannot be named.
    func discardFinishedForAgent(id: String) throws -> [String: Any] {
        let url = try readableFile(id: id)
        try FileManager.default.removeItem(at: url)
        finishedIDs.removeAll { $0 == id }
        return ["id": id, "discarded": true]
    }

    private func readableFile(id: String) throws -> URL {
        guard finishedIDs.contains(id) else { throw AgentError("NOT_FOUND", "Only a narration stopped in this session can be read here.") }
        let url = try Self.destination(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError("NOT_FOUND", "That narration file is gone.") }
        return url
    }

    func stopForAgent() async throws -> [String: Any] { try await stop() }

    func pauseForAgent() throws -> [String: Any] { try pause(); return statusForAgent() }
    func resumeForAgent() throws -> [String: Any] { try resume(); return statusForAgent() }

    func restartForAgent() async throws -> [String: Any] {
        let id = try await restart()
        return ["id": id, "restarted": true, "countdown_seconds": NarrationPlan.countdownSeconds, "max_duration_seconds": NarrationPlan.maximumDurationSeconds]
    }

    func statusForAgent() -> [String: Any] {
        var status: [String: Any] = ["phase": String(describing: phase), "session_id": sessionID ?? NSNull(), "elapsed_ms": elapsedMs, "paused": phase == .paused]
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

    /// Personal recordings take an external camera (an iPhone through Continuity Camera counts) when one is connected.
    /// Agent takes always use the built-in front camera, as before.
    static func preferredCamera(for profile: NarrationPlan.Profile) -> AVCaptureDevice? {
        if let chosen = CameraSelection.selectedDevice() { return chosen }
        if profile.camera == .highest {
            // Continuity Camera (an iPhone) is found by its flag, because without the Info.plist opt-in it reports as a built-in camera.
            // Anything that is not the front camera counts as external, so the Mac's own camera is never picked here.
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            if let external = discovery.devices.first(where: { $0.isContinuityCamera || $0.deviceType == .external || $0.position != .front }) {
                NSLog("My Man [Narration] using external camera: \(external.localizedName)")
                return external
            }
            NSLog("My Man [Narration] no external camera found; using the front camera")
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    /// The profile with its output size and bitrate fitted to the camera that will be used. Other profiles are unchanged.
    static func resolvedProfile(_ base: NarrationPlan.Profile) throws -> NarrationPlan.Profile {
        guard base.camera == .highest else { return base }
        guard let camera = preferredCamera(for: base), let format = largestFormat(camera) else { return base }
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return NarrationPlan.squareProfile(from: base, sensorWidth: Int(d.width), sensorHeight: Int(d.height))
    }

    /// The camera's largest format that can run at 30 fps, or nil if none can.
    static func largestFormat(_ camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func pixels(_ format: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        let candidates = camera.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        return candidates.max(by: { pixels($0) < pixels($1) })
    }

    /// Switches the camera to its largest format that can run at 30 fps. Leaves the camera as it was if none fits.
    static func useLargestFormat(_ camera: AVCaptureDevice) {
        guard let best = largestFormat(camera) else { return }
        do {
            try camera.lockForConfiguration()
            camera.activeFormat = best
            let thirty = CMTime(value: 1, timescale: 30)
            camera.activeVideoMinFrameDuration = thirty
            camera.activeVideoMaxFrameDuration = thirty
            camera.unlockForConfiguration()
        } catch {
            NSLog("My Man [Narration] could not select the largest camera format: \(error)")
        }
    }

    private static func permissionError(_ type: AVMediaType) -> AgentError {
        let device = type == .video ? "Camera" : "Microphone"
        return AgentError("PERMISSION_REQUIRED", "Allow \(device) for My Man in Privacy, then try again.")
    }

    private static func makeSession(sink: NarrationSink, profile: NarrationPlan.Profile) throws -> AVCaptureSession {
        let capture = AVCaptureSession()
        // .highest sets no preset (inputPriority is iOS-only), so the camera format chosen below is what the session uses.
        switch profile.camera {
        case .highest: break
        case .hd1280x720: capture.sessionPreset = capture.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
        case .vga640x480: capture.sessionPreset = .vga640x480
        }
        guard let camera = preferredCamera(for: profile),
              let microphone = AVCaptureDevice.default(for: .audio) else {
            throw AgentError("DEVICE_UNAVAILABLE", "No front camera or microphone is available on this Mac.")
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard capture.canAddInput(cameraInput), capture.canAddInput(microphoneInput) else {
            throw AgentError("DEVICE_UNAVAILABLE", "The camera or microphone could not be added.")
        }
        capture.addInput(cameraInput); capture.addInput(microphoneInput)
        if profile.camera == .highest { Self.useLargestFormat(camera) }
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
    // Pause: nothing is written while paused. On resume the paused gap is removed from the timeline, so the file is continuous.
    private var paused = false
    private var resumePending = false
    /// Total paused time removed from the timeline so far.
    private var offset = CMTime.zero
    /// End of the last video frame written, on the output timeline.
    private var lastEnd = CMTime.invalid
    private var firstPTS = CMTime.invalid
    private let lockedMs = NSLock()
    private var recordedValue = 0
    private static let fallbackFrame = CMTime(value: 1, timescale: 30)

    /// Recorded time so far in milliseconds, without paused time.
    var recordedMs: Int { lockedMs.withLock { recordedValue } }

    init(url: URL, profile: NarrationPlan.Profile) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: profile.width,
            AVVideoHeightKey: profile.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: profile.videoBitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100, AVEncoderBitRateKey: profile.audioBitrate,
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video); writer.add(audio)
        super.init()
    }

    /// Called on the main actor. Pausing drops frames and sound; resuming removes the gap from the timeline.
    func setPaused(_ on: Bool) {
        queue.async {
            if on { self.paused = true } else if self.paused { self.paused = false; self.resumePending = true }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if output is AVCaptureVideoDataOutput {
            if paused { return }
            let raw = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !started {
                // The first video frame sets the clock: the wall time now, and the source time the file starts at.
                writer.startWriting()
                writer.startSession(atSourceTime: raw)
                started = true
                startedAtEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
                firstPTS = raw
            }
            if resumePending {
                // The first frame after a resume: close the paused gap so the frames sit right after the last one.
                let candidate = CMTimeSubtract(raw, offset)
                if lastEnd.isValid, CMTimeCompare(candidate, lastEnd) > 0 {
                    offset = CMTimeAdd(offset, CMTimeSubtract(candidate, lastEnd))
                }
                resumePending = false
            }
            guard video.isReadyForMoreMediaData, let shifted = Self.shifted(sampleBuffer, by: offset) else { return }
            video.append(shifted)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            lastEnd = CMTimeAdd(CMTimeSubtract(raw, offset), duration.isValid ? duration : Self.fallbackFrame)
            let ms = Int(CMTimeGetSeconds(CMTimeSubtract(lastEnd, firstPTS)) * 1000)
            lockedMs.withLock { recordedValue = max(0, ms) }
        } else if started, !paused, !resumePending, audio.isReadyForMoreMediaData, let shifted = Self.shifted(sampleBuffer, by: offset) {
            // Sound waits for the first video frame after a resume, so it stays in step with the picture.
            audio.append(shifted)
        }
    }

    /// The buffer with its times moved back by `offset`. Returns the buffer unchanged when there is no offset.
    static func shifted(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(offset, .zero) == 0 { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Abandons the file and removes it. Runs on the write queue, so no sample can arrive after it.
    func discard(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                continuation.resume()
            }
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
