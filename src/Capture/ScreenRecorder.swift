import AppKit
import AVFoundation
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
            let coordinator = SelectionOverlayCoordinator(frozenCapture: nil)
            coordinator.delegate = self
            self.selection = coordinator
            coordinator.showAll()
        }
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
                config.showsCursor = true
                config.capturesAudio = true
                config.captureMicrophone = true
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
                let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()

                self.stream = stream
                self.recordingOutput = output
                self.outputURL = url
                self.startedAt = Date()
                self.isRecording = true
                self.activeRegion = regionAppKit
                WebcamBubble.shared.preferredRegion = regionAppKit
                Analytics.track("screen_recording_started")
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
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
            recordingOutput = nil
            outputURL = nil
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
                           NSPasteboard.general.clearContents()
                           NSPasteboard.general.writeObjects([url as NSURL])
                       })
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
        let size = CGSize(width: 200, height: 40)
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
            onRecord: { [weak self] in self?.confirmRecord() },
            onCancel: { [weak self] in self?.cancelPending() })
        let panel = FloatingPanel(content: view, becomesKey: false, fixedSize: true)
        panel.onDismiss = { [weak self] in self?.confirmPanel = nil }
        confirmPanel = panel
        let size = CGSize(width: 190, height: 44)
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
        pendingRegion = nil
        confirmPanel?.orderOut(nil)
        confirmPanel = nil
        // The border stays up — it IS the "this is what's recording" chrome.
        start(regionAppKit: region)
    }

    private func cancelPending() {
        pendingRegion = nil
        confirmPanel?.orderOut(nil)
        confirmPanel = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        isBusy = false
    }

    func selectionOverlayDidCancel() {
        selection?.hideAll()
        selection = nil
        isBusy = false
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
    private var session: AVCaptureSession?

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
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        let view = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.cornerRadius = diameter / 2
        layer.masksToBounds = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)

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

        if let region {
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

        self.panel = panel
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        isOn = true
        Analytics.track("webcam_bubble_on")
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        let stopping = session
        DispatchQueue.global(qos: .userInitiated).async { stopping?.stopRunning() }
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
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
    var onRecord: () -> Void
    var onCancel: () -> Void

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
            IconView(icon: .close, size: 13, color: MM.Colors.textTertiary)
                .clickable(minSize: 24)
                .onTapGesture(perform: onCancel)
                .help("Cancel")
        }
        .padding(.horizontal, 12)
        .frame(width: 190, height: 44)
        .background(
            Capsule()
                .fill(MM.Colors.background)
                .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
        )
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
            IconView(icon: webcam.isOn ? .camera : .cameraOff, size: 14,
                     color: webcam.isOn ? MM.Colors.textPrimary : MM.Colors.textTertiary)
                .clickable(minSize: 24)
                .onTapGesture { webcam.toggle() }
                .help(webcam.isOn ? "Turn webcam bubble off" : "Turn webcam bubble on")
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(MM.Colors.background)
                .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
        )
        .frame(width: 200, height: 40)
        .onReceive(clock) { now = $0 }
    }

    private var elapsed: String {
        guard let start = recorder.startedAt else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
