import AppKit
import AVFoundation
import CoreAudio
import GRDB
import ScreenCaptureKit
import SwiftUI

struct ScreenRecording: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recording"
    var id: String
    var path: String
    var duration: Int
    var createdAt: Date
    var transcript: String = ""

    var title: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

// The Loom killer, v2: the native macOS content picker chooses WHAT to
// record (full display, one window, one app), an optional floating webcam
// bubble is captured right into the frame, and the result is a movie file
// with mic + system audio (SCRecordingOutput encodes). No cloud, no
// account — the finish toast hands you Open and Copy.
// macOS 15+ (SCRecordingOutput/mic capture); the tile hides below that.

@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    /// True from tile-click to file-saved — covers the async spin-up window
    /// so meeting detection can never mistake our own mic for a call.
    private(set) var isBusy = false

    private var stream: SCStream?
    private var recordingOutput: Any? // SCRecordingOutput, typed loosely for the 14.x floor
    private var outputURL: URL?
    private var pill: FloatingPanel?
    private var streamConfiguration: SCStreamConfiguration?
    /// A Loom-style recording without the narrator's voice is missing the
    /// point — the microphone records by default, and the pill toggle
    /// remembers an explicit opt-out. (The "unusable noise" that once made
    /// this opt-in traced to forcing sampleRate/channelCount on the stream,
    /// not to combining the tracks — see start(regionAppKit:).)
    @Published private(set) var microphoneEnabled =
        UserDefaults.standard.object(forKey: "mm.screenRecordingMicrophone") as? Bool ?? true
    /// Smoothed 0...1 level read from the microphone stream being saved.
    @Published private(set) var microphoneLevel: CGFloat = 0
    /// Human name of the mic actually being recorded — shown on the pill so
    /// "why is my voice muffled" is answerable at a glance.
    @Published private(set) var microphoneName: String?
    private let narration = NarrationTrack()
    private var micLevelTimer: Timer?

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    func toggle() {
        if isRecording {
            stop()
            return
        }
        // Failsafe: a stranded selection (or stuck busy-latch) must never
        // brick the button — clear it and start fresh.
        if let selection {
            selection.hideAll()
            self.selection = nil
            isBusy = false
        }
        if pendingRegion != nil || confirmPanel != nil {
            cancelPending()
        }
        beginRegionSelection()
    }

    // MARK: Picking what to record — drag a region, click for full screen

    private var selection: SelectionOverlayCoordinator?
    private var pendingRegion: CGRect?
    /// The region being recorded (AppKit coords) — the webcam bubble must
    /// live INSIDE it, or it films the void.
    private(set) var activeRegion: CGRect?
    private var confirmPanel: FloatingPanel?
    private var countdownPanel: FloatingPanel?
    private var borderPanel: NSPanel?

    private func beginRegionSelection() {
        guard #available(macOS 15.0, *), !isBusy else { return }
        isBusy = true
        // The detector must never read our spin-up as a meeting starting.
        NotificationCenter.default.post(name: MeetingDetector.suppressNotification, object: nil)
        Task { @MainActor in
            // PERMISSIONS FIRST. Nothing records — nothing even *appears* —
            // until screen access is granted, and the camera question is
            // settled before capture so no prompt ever overlaps a live
            // recording.
            guard await CaptureEngine.shared.authorizeInteractively() else {
                self.isBusy = false
                Toast.show("Grant Screen Recording for My Man, then try again",
                           systemImage: "video.slash")
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            let wantsBubble = UserDefaults.standard.object(forKey: "mm.webcamBubble") as? Bool ?? true
            if wantsBubble, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .video) { _ in continuation.resume() }
                }
            }
            if self.microphoneEnabled, !(await self.authorizeMicrophoneIfNeeded()) {
                self.microphoneEnabled = false
                UserDefaults.standard.set(false, forKey: "mm.screenRecordingMicrophone")
                Toast.show("Microphone access is off — recording screen audio only", systemImage: "mic.slash")
            }
            let coordinator = SelectionOverlayCoordinator(frozenCapture: nil)
            coordinator.delegate = self
            self.selection = coordinator
            coordinator.showAll()
        }
    }

    /// Reading the default input device is a blocking round-trip to
    /// coreaudiod that can stall for seconds while it switches devices
    /// (MYMAN-4: a 3s main-thread hang). Never call the sync version from the
    /// main actor — use `defaultInputDeviceOffMain()`.
    private nonisolated static let halQueue =
        DispatchQueue(label: "com.muckstack.myman.screenrecorder.hal")

    private nonisolated static func defaultInputDeviceOffMain() async -> (uid: String, name: String)? {
        await withCheckedContinuation { continuation in
            halQueue.async { continuation.resume(returning: defaultInputDevice()) }
        }
    }

    /// The system-default input device — UID for SCK, name for the pill.
    private nonisolated static func defaultInputDevice() -> (uid: String, name: String)? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        func stringProperty(_ selector: AudioObjectPropertySelector) -> String? {
            var value: CFString = "" as CFString
            var valueSize = UInt32(MemoryLayout<CFString>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &valueSize, &value) == noErr
            else { return nil }
            return value as String
        }
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID) else { return nil }
        return (uid, stringProperty(kAudioObjectPropertyName) ?? "Microphone")
    }

    /// AppKit global rect (bottom-left origin) → CG global (top-left).
    private static func cgRect(from appKitRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: appKitRect.minX,
                      y: primaryHeight - appKitRect.maxY,
                      width: appKitRect.width, height: appKitRect.height)
    }

    @available(macOS 15.0, *)
    fileprivate func start(regionAppKit: CGRect?) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let cgRegion = regionAppKit.map(Self.cgRect(from:))
                let display = content.displays.first(where: { d in
                    cgRegion.map { d.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
                }) ?? content.displays.first
                guard let display else {
                    self.isBusy = false
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                if let cgRegion {
                    // Crop to the dragged region, display-local coordinates.
                    let local = CGRect(x: cgRegion.minX - display.frame.minX,
                                       y: cgRegion.minY - display.frame.minY,
                                       width: cgRegion.width, height: cgRegion.height)
                    config.sourceRect = local
                    // H.264 wants even dimensions.
                    config.width = max(2, Int(local.width * scale) & ~1)
                    config.height = max(2, Int(local.height * scale) & ~1)
                } else {
                    config.width = max(2, Int(filter.contentRect.width * scale) & ~1)
                    config.height = max(2, Int(filter.contentRect.height * scale) & ~1)
                }
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                // Preserve the display's real pixels. Automatic capture can
                // choose a nominal surface on some Retina displays, which
                // looks soft after sharing or re-encoding.
                config.captureResolution = .best
                config.queueDepth = 8
                config.showsCursor = true
                config.capturesAudio = true
                // The mic is deliberately NOT SCK's job: captureMicrophone
                // echo-cancels the mic against system audio, leaving
                // narration watery and quiet on every device we tried.
                // NarrationTrack records it through our own raw pipeline
                // and muxes it in after the stop.
                config.captureMicrophone = false
                self.microphoneName = self.microphoneEnabled
                    ? ((await Self.defaultInputDeviceOffMain())?.name ?? "Microphone") : nil
                // NEVER force sampleRate/channelCount here: when the active
                // output device runs at a different rate (AirPods, DACs,
                // monitor speakers), the forced format comes out as loud
                // tonal noise in the recording. SCK's native format is
                // always correct for the device.
                config.excludesCurrentProcessAudio = true

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss" // fixed: locale slashes break paths
                let url = SettingsStore.shared.screenshotFolderURL
                    .appendingPathComponent("Recording \(formatter.string(from: Date())).mov")
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

                let recordingConfig = SCRecordingOutputConfiguration()
                recordingConfig.outputURL = url
                recordingConfig.outputFileType = .mov
                // HEVC delivers materially cleaner text/UI at the same (or
                // smaller) file size. Fall back only when a Mac cannot write
                // it, preserving a universally playable H.264 recording.
                if recordingConfig.availableVideoCodecTypes.contains(.hevc) {
                    recordingConfig.videoCodecType = .hevc
                }
                let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)

                // Our warm dictation engine's voice-processing unit ducks
                // system audio + AECs the mic machine-wide — release it for
                // the duration or the recording comes out faint and whistly.
                AudioCapture.shared.suppressVoiceProcessing = true

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()
                if self.microphoneEnabled {
                    self.narration.start(alongside: url)
                }
                self.micLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.microphoneLevel = self.narration.currentLevel()
                    }
                }

                self.stream = stream
                self.streamConfiguration = config
                self.recordingOutput = output
                self.outputURL = url
                self.startedAt = Date()
                self.isRecording = true
                self.activeRegion = regionAppKit
                WebcamBubble.shared.preferredRegion = regionAppKit
                if SettingsStore.shared.cursorEffects {
                    CursorEffects.shared.show(regionAppKit: regionAppKit)
                }
                Analytics.track("screen_recording_started",
                                ["cursor_effects": SettingsStore.shared.cursorEffects])
                self.showPill()
                // The bubble comes on with the recording (prompting for
                // camera the first time); the pill toggle remembers your
                // last choice for next time.
                if UserDefaults.standard.object(forKey: "mm.webcamBubble") as? Bool ?? true,
                   AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                    WebcamBubble.shared.turnOn()
                }
            } catch {
                NSLog("My Man [Record] start failed: \(error)")
                AudioCapture.shared.suppressVoiceProcessing = false
                self.isBusy = false
                self.borderPanel?.orderOut(nil)
                self.borderPanel = nil
                Toast.show("Screen recording couldn't start — check Screen Recording access",
                           systemImage: "video.slash")
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        let url = outputURL
        let duration = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        startedAt = nil
        dismissPill()
        borderPanel?.orderOut(nil)
        borderPanel = nil
        activeRegion = nil
        WebcamBubble.shared.preferredRegion = nil
        WebcamBubble.shared.turnOff()
        WebcamBubble.shared.resetPosition()
        CursorEffects.shared.hide()
        micLevelTimer?.invalidate()
        micLevelTimer = nil
        microphoneLevel = 0
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
            streamConfiguration = nil
            recordingOutput = nil
            outputURL = nil
            // Fold the self-captured narration into the movie BEFORE the
            // toast — "Open" must play the finished file.
            if let url { await self.narration.finish(into: url) }
            AudioCapture.shared.suppressVoiceProcessing = false
            isBusy = false
            Analytics.track("screen_recording_saved", ["duration_s": duration])
            guard let url else { return }
            let record = ScreenRecording(id: UUID().uuidString, path: url.path,
                                         duration: duration, createdAt: Date())
            try? await Database.shared.write { try record.insert($0) }
            // Narration → text → brain, in the background. The recording is
            // useful the moment it saves; the transcript catches up.
            self.transcribeAndSync(record)
            Toast.show("Recording saved",
                       actionLabel: "Open",
                       action: { NSWorkspace.shared.open(url) },
                       secondaryLabel: "Copy",
                       secondaryAction: {
                           // One item, two faces: plain text (a bare NSURL
                           // pastes as NOTHING in most text fields) plus the
                           // file URL for Finder-style paste targets.
                           let item = NSPasteboardItem()
                           item.setString(url.path, forType: .string)
                           item.setString(url.absoluteString, forType: .fileURL)
                           NSPasteboard.general.clearContents()
                           NSPasteboard.general.writeObjects([item])
                       })
        }
    }

    /// Throw away the current movie and return to selection. Unlike Stop this
    /// never writes a database row, transcript, or Brain entry.
    func restart() {
        guard isRecording else { return }
        let region = activeRegion
        isRecording = false
        dismissPill()
        borderPanel?.orderOut(nil)
        borderPanel = nil
        // No recording, no effects: the trail must never run during the
        // countdown/re-selection between takes.
        CursorEffects.shared.hide()
        narration.stopDiscarding()
        micLevelTimer?.invalidate()
        micLevelTimer = nil
        microphoneLevel = 0
        let discardedURL = outputURL
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
            streamConfiguration = nil
            recordingOutput = nil
            outputURL = nil
            if let discardedURL { try? FileManager.default.removeItem(at: discardedURL) }
            activeRegion = nil
            // Restart preserves the exact frame and live camera panel. The
            // only thing discarded is the partial movie.
            pendingRegion = region ?? .zero
            if let region { showBorder(around: region) }
            showCountdown(for: region ?? .zero)
        }
    }

    // MARK: Transcription → brain

    private func transcribeAndSync(_ record: ScreenRecording) {
        Task { @MainActor in
            if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != .parakeet {
                await TranscriptionService.shared.load(kind: .parakeet)
            }
            let text = await Self.transcribeMovie(at: URL(fileURLWithPath: record.path))
            var updated = record
            updated.transcript = text
            try? await Database.shared.write { [updated] in try updated.update($0) }
            Brain.syncRecording(id: record.id, filePath: record.path,
                                duration: record.duration, transcript: text,
                                createdAt: record.createdAt)
        }
    }

    /// All audio tracks of the movie (mic + system), streamed as 16k mono
    /// and transcribed in 60s chunks — bounded memory at any length.
    private static func transcribeMovie(at url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return "" }
        var parts: [String] = []
        for track in tracks {
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }
            var buffer: [Float] = []
            let chunk = 16000 * 60
            func drain(_ final: Bool) async {
                while buffer.count >= chunk || (final && !buffer.isEmpty) {
                    let take = min(chunk, buffer.count)
                    let piece = Array(buffer.prefix(take))
                    buffer.removeFirst(take)
                    let text = await TranscriptionService.shared.transcribe(piece)
                    if !text.isEmpty { parts.append(text) }
                    if final && buffer.isEmpty { break }
                }
            }
            while let sample = output.copyNextSampleBuffer() {
                if let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                totalLengthOut: &length, dataPointerOut: &pointer)
                    if let pointer {
                        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                            buffer.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / 4))
                        }
                    }
                }
                await drain(false)
            }
            await drain(true)
        }
        return parts.joined(separator: " ")
    }

    // MARK: Pill — same top-right recording indicator contract as meetings

    private func showPill() {
        guard pill == nil else { return }
        let panel = FloatingPanel(content: RecordingPillView(recorder: self), becomesKey: false, fixedSize: true)
        panel.onDismiss = { [weak self] in self?.pill = nil }
        pill = panel
        let size = CGSize(width: 320, height: 40)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Below where the meeting pill lives, so both can show.
        panel.setFrame(
            NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 72,
                   width: size.width, height: size.height),
            display: true
        )
        panel.orderFrontRegardless()
    }

    private func dismissPill() {
        pill?.orderOut(nil)
        pill = nil
    }

    func toggleMicrophone() {
        let enabled = !microphoneEnabled
        Task { @MainActor in
            if enabled {
                guard await self.authorizeMicrophoneIfNeeded() else {
                    Toast.show("Allow Microphone for My Man to record your voice", systemImage: "mic.slash")
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                    return
                }
            }
            self.microphoneEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "mm.screenRecordingMicrophone")
            guard self.isRecording, let url = self.outputURL else { return }
            if enabled {
                self.microphoneName = (await Self.defaultInputDeviceOffMain())?.name ?? "Microphone"
                if self.narration.isActive {
                    self.narration.setMuted(false)
                } else if let started = self.startedAt {
                    // Switched on mid-take: the track muxes in at the
                    // elapsed offset so timing stays true.
                    self.narration.start(alongside: url, videoStartedAt: started)
                }
            } else {
                self.microphoneName = nil
                self.narration.setMuted(true)
            }
            Analytics.track("screen_recording_microphone", ["enabled": enabled])
        }
    }

    private func authorizeMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default: return false
        }
    }
}

extension ScreenRecorder: SelectionOverlayDelegate {
    func selectionOverlayDidComplete(with rect: CGRect) {
        selection?.hideAll()
        selection = nil
        guard #available(macOS 15.0, *) else {
            isBusy = false
            return
        }
        // A bare click (no real drag) means the whole screen — no confirm.
        let isClick = rect.width < 10 || rect.height < 10
        if isClick {
            start(regionAppKit: nil)
            return
        }
        // Region chosen: outline it and wait for the explicit Record click.
        pendingRegion = rect
        showBorder(around: rect)
        // Make the webcam placement part of the selection state, not the
        // recording state. This lets people see and position themselves
        // before committing, while keeping the bubble inside the chosen
        // frame from the first recorded frame.
        WebcamBubble.shared.preferredRegion = rect
        WebcamBubble.shared.resetPosition()
        if UserDefaults.standard.object(forKey: "mm.webcamBubble") as? Bool ?? true,
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            WebcamBubble.shared.turnOn()
        }
        showConfirm(for: rect)
    }

    // MARK: Region outline + confirm (CleanShot-style)

    /// The outline lives OUTSIDE the captured rect, so it frames the
    /// recording without ever appearing in it. It stays up for the whole
    /// recording — you always know exactly what's in frame.
    private func showBorder(around region: CGRect) {
        let inset: CGFloat = 3
        let frame = region.insetBy(dx: -inset, dy: -inset)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // pure chrome — clicks pass through
        panel.contentView = RegionBorderView()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        borderPanel = panel
    }

    private func showConfirm(for region: CGRect) {
        let view = RecordConfirmView(
            recorder: self,
            onRecord: { [weak self] in self?.confirmRecord() },
            onCancel: { [weak self] in self?.cancelPending() },
            onToggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            onToggleCamera: { WebcamBubble.shared.toggle() })
        let panel = FloatingPanel(content: view, becomesKey: false, fixedSize: true)
        panel.onDismiss = { [weak self] in self?.confirmPanel = nil }
        confirmPanel = panel
        let size = CGSize(width: 262, height: 44)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var x = region.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        var y = region.minY - size.height - 10
        if y < screen.minY + 8 { y = region.maxY + 10 }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
    }

    private func confirmRecord() {
        guard #available(macOS 15.0, *), let region = pendingRegion else { return }
        confirmPanel?.orderOut(nil)
        confirmPanel = nil
        showCountdown(for: region)
    }

    private func showCountdown(for region: CGRect) {
        let view = RecordCountdownView(
            onFinished: { [weak self] in self?.startAfterCountdown(region) },
            onCancel: { [weak self] in self?.cancelPending() })
        let panel = FloatingPanel(content: view, becomesKey: false, fixedSize: true)
        panel.onDismiss = { [weak self] in self?.countdownPanel = nil }
        countdownPanel = panel
        let size = CGSize(width: 262, height: 44)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var x = region.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        var y = region.minY - size.height - 10
        if y < screen.minY + 8 { y = region.maxY + 10 }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func startAfterCountdown(_ region: CGRect) {
        guard #available(macOS 15.0, *) else { return }
        guard pendingRegion != nil else { return }
        pendingRegion = nil
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        // The border stays up — it is the "this is what's recording" chrome.
        start(regionAppKit: region == .zero ? nil : region)
    }

    private func cancelPending() {
        pendingRegion = nil
        confirmPanel?.orderOut(nil)
        confirmPanel = nil
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        WebcamBubble.shared.preferredRegion = nil
        WebcamBubble.shared.turnOff()
        WebcamBubble.shared.resetPosition()
        isBusy = false
    }

    func selectionOverlayDidCancel() {
        selection?.hideAll()
        selection = nil
        isBusy = false
    }
}

/// Observes the ScreenCaptureKit microphone samples solely for the control
/// indicator. Recording itself remains owned by `SCRecordingOutput`, so the
/// meter cannot alter the audio written to disk.
@available(macOS 15.0, *)
private final class MicrophoneLevelMonitor: NSObject, SCStreamOutput {
    var onLevel: (@MainActor (CGFloat) -> Void)?
    private var smoothedLevel: CGFloat = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .microphone,
              CMSampleBufferDataIsReady(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var data: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &data) == kCMBlockBufferNoErr,
              let data, totalLength > 0 else { return }

        let bits = Int(asbd.pointee.mBitsPerChannel)
        let sampleCount = totalLength / max(1, bits / 8)
        guard sampleCount > 0 else { return }
        var sum: Double = 0
        if bits == 32, (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            data.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                for index in 0..<sampleCount { sum += Double(samples[index] * samples[index]) }
            }
        } else if bits == 16 {
            data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for index in 0..<sampleCount {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sum += value * value
                }
            }
        } else {
            return
        }
        let rms = sqrt(sum / Double(sampleCount))
        let normalized = min(1, max(0, (rms - 0.008) * 9))
        smoothedLevel = max(CGFloat(normalized), smoothedLevel * 0.76)
        let level = smoothedLevel
        Task { @MainActor [onLevel] in onLevel?(level) }
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            NSLog("My Man [Record] failed: \(error)")
            self.stop()
        }
    }
}

// MARK: - Webcam bubble (captured into the recording, Loom-style)

@MainActor
final class WebcamBubble: ObservableObject {
    static let shared = WebcamBubble()

    @Published private(set) var isOn = false
    /// When a region recording is live, the bubble spawns inside it.
    var preferredRegion: CGRect?
    private var panel: NSPanel?
    private var lastFrame: NSRect?
    private var sessionRunner: CaptureSessionRunner?

    func toggle() {
        UserDefaults.standard.set(!isOn, forKey: "mm.webcamBubble")
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.begin() }
                }
            }
        default:
            // macOS won't re-prompt — land exactly where the fix happens.
            Toast.show("Allow Camera for My Man, then tap the webcam button again",
                       systemImage: "video.slash")
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func begin() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        // Inside the recorded region when there is one (scaled down for
        // small regions); screen corner otherwise.
        let region = preferredRegion
        let diameter: CGFloat = region.map {
            max(80, min(180, min($0.width, $0.height) * 0.35))
        } ?? 180
        let view = WebcamBubbleView(diameter: diameter, session: session)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu // above content → included in the capture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true // drag it anywhere
        panel.contentView = view

        if let lastFrame {
            panel.setFrame(lastFrame, display: true)
        } else if let region {
            panel.setFrame(
                NSRect(x: region.minX + 14, y: region.minY + 14,
                       width: diameter, height: diameter),
                display: true)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(x: visible.minX + 24, y: visible.minY + 24,
                       width: diameter, height: diameter),
                display: true)
        }
        panel.orderFrontRegardless()
        view.playEntrance()

        self.panel = panel
        let runner = CaptureSessionRunner(session: session)
        self.sessionRunner = runner
        runner.start()
        isOn = true
        Analytics.track("webcam_bubble_on")
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        sessionRunner?.stop()
        sessionRunner = nil
        lastFrame = panel?.frame
        panel?.orderOut(nil)
        panel = nil
    }

    /// Reset only for a new selected recording region. Camera on/off during a
    /// take deliberately keeps the user's dragged position.
    func resetPosition() { lastFrame = nil }
}

/// A recognizable, camera-first signature for My Man recordings. The shape is
/// a soft square rather than a generic circular webcam crop, with a tiny live
/// mark that stays legible when the video is shared at small sizes.
private final class WebcamBubbleView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(diameter: CGFloat, session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        guard let layer else { return }
        let radius = diameter * 0.27
        layer.cornerRadius = radius
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.borderWidth = 2
        layer.borderColor = NSColor.white.withAlphaComponent(0.88).cgColor

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds.insetBy(dx: 3, dy: 3)
        previewLayer.cornerRadius = max(0, radius - 3)
        previewLayer.masksToBounds = true
        layer.addSublayer(previewLayer)

        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { nil }

    func playEntrance() {
        guard let layer else { return }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.72, 1.06, 0.98, 1.0]
        scale.keyTimes = [0, 0.58, 0.82, 1]
        scale.duration = 0.42
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.add(scale, forKey: "myman.camera-bloom")
        layer.add(fade, forKey: "myman.camera-fade")
    }
}

/// AVCaptureSession start/stop can block. Keep it off the main actor while
/// serializing calls to the session on one dedicated queue.
private final class CaptureSessionRunner: @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.muckstack.myman.webcam")

    init(session: AVCaptureSession) { self.session = session }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }
}

/// 2pt red frame drawn at the panel's edge — the panel sits 3pt outside
/// the captured rect, so this chrome never enters the video.
private final class RegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                xRadius: 4, yRadius: 4)
        path.lineWidth = 2.5
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

private struct RecordConfirmView: View {
    @ObservedObject var recorder: ScreenRecorder
    var onRecord: () -> Void
    var onCancel: () -> Void
    var onToggleMicrophone: () -> Void
    var onToggleCamera: () -> Void
    @ObservedObject private var webcam = WebcamBubble.shared

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onRecord) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Record")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background)
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(MM.Colors.textPrimary))
                .fixedSize()
                .clickable(minSize: 28)
            }
            .buttonStyle(.plain)
            Button(action: onToggleCamera) {
                IconView(icon: webcam.isOn ? .recordScreen : .cameraOff, size: 14,
                         color: webcam.isOn ? MM.Colors.textPrimary : MM.Colors.danger)
                    .clickable(minSize: 32)
            }
            .buttonStyle(.plain)
            .help(webcam.isOn ? "Camera on — click to hide" : "Camera off — click to show")
            Button(action: onToggleMicrophone) {
                MicrophoneToggleIcon(enabled: recorder.microphoneEnabled)
                    .clickable(minSize: 32)
            }
            .buttonStyle(.plain)
            .help(recorder.microphoneEnabled ? "Microphone on — click to mute" : "Microphone off — click to include your voice")
            IconView(icon: .close, size: 13, color: MM.Colors.textTertiary)
                .clickable(minSize: 32)
                .onTapGesture(perform: onCancel)
                .help("Cancel")
        }
        .padding(.horizontal, 12)
        .frame(width: 262, height: 44)
        .background(
            Capsule()
                .fill(MM.Colors.background)
                .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
        )
    }
}

/// The supplied My Man microphone icons, with a deliberately loud off state:
/// red means your voice will not be included in this recording.
private struct MicrophoneToggleIcon: View {
    let enabled: Bool
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        IconView(icon: enabled ? .mic : .micOff, size: 16,
                 color: enabled ? activeColor : MM.Colors.danger)
            .scaleEffect(enabled ? 1 + recorder.microphoneLevel * 0.12 : 1)
            .animation(.easeOut(duration: 0.08), value: recorder.microphoneLevel)
    }

    private var activeColor: Color {
        recorder.microphoneLevel > 0.035 ? .green : MM.Colors.textPrimary
    }
}

private struct RecordCountdownView: View {
    var onFinished: () -> Void
    var onCancel: () -> Void
    @State private var count = 3

    var body: some View {
        HStack(spacing: 12) {
            Text("Recording in")
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textSecondary)
            Text("\(count)")
                .font(MM.Fonts.outfit(22, .bold))
                .foregroundStyle(MM.Colors.textPrimary)
                .contentTransition(.numericText())
                .frame(width: 28)
            Spacer()
            IconView(icon: .close, size: 13, color: MM.Colors.textTertiary)
                .clickable(minSize: 32)
                .onTapGesture(perform: onCancel)
                .help("Cancel recording")
        }
        .padding(.horizontal, 14)
        .frame(width: 262, height: 44)
        .background(Capsule().fill(MM.Colors.background)
            .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1)))
        .task {
            for next in [2, 1] {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                withAnimation(MM.Motion.elastic) { count = next }
            }
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            onFinished()
        }
    }
}

private struct RecordingPillView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var webcam = WebcamBubble.shared
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: .recordScreen, size: 14, color: .red.opacity(0.85))
            Text(elapsed)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(MM.Colors.textSecondary)
                .frame(width: 42, alignment: .leading)
            IconView(icon: webcam.isOn ? .recordScreen : .cameraOff, size: 14,
                     color: webcam.isOn ? MM.Colors.textPrimary : MM.Colors.danger)
                .clickable(minSize: 24)
                .onTapGesture { webcam.toggle() }
                .help(webcam.isOn ? "Turn webcam bubble off" : "Turn webcam bubble on")
            Button(action: { recorder.toggleMicrophone() }) {
                MicrophoneToggleIcon(enabled: recorder.microphoneEnabled)
                    .clickable(minSize: 32)
            }
            .buttonStyle(.plain)
            .help(recorder.microphoneEnabled
                  ? "Recording \(recorder.microphoneName ?? "microphone") — click to mute"
                  : "Include microphone")
            Button {
                recorder.stop()
            } label: {
                Text("Stop")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.background)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(MM.Colors.textPrimary))
                    .fixedSize()
                    .clickable(minSize: 24)
            }
            .buttonStyle(.plain)
            Button("Restart") {
                recorder.restart()
            }
            .buttonStyle(.plain)
            .font(MM.Fonts.secondary)
            .foregroundStyle(MM.Colors.textSecondary)
            .clickable(minSize: 48)
            .help("Discard this take and record again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(MM.Colors.background)
                .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
        )
        .frame(width: 320, height: 40)
        .onReceive(clock) { now = $0 }
    }

    private var elapsed: String {
        guard let start = recorder.startedAt else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
