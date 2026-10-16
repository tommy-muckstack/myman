import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

enum RecordingDevices {
    static var camera: AVCaptureDevice? {
        let uid = UserDefaults.standard.string(forKey: "recordingCameraUID") ?? ""
        return AVCaptureDevice.devices(for: .video).first { $0.uniqueID == uid } ?? AVCaptureDevice.default(for: .video)
    }
}

@MainActor final class RecordingSourcePicker {
    static let shared = RecordingSourcePicker()
    private var panel: FloatingPanel?
    func show() {
        if let panel { panel.present(); return }
        let view = RecordingSourceView { [weak self] in self?.panel?.dismiss() }
        let panel = FloatingPanel(content: view, fixedSize: true)
        panel.setContentSize(NSSize(width: 520, height: 490)); panel.dismissesOnResign = false
        panel.onDismiss = { [weak self] in self?.panel = nil }
        self.panel = panel; panel.present()
    }
}

struct RecordingSourceView: View {
    var dismiss: () -> Void
    @State private var source = "region"
    @State private var windows: [SCWindow] = []
    @State private var windowID = ""
    @State private var microphone = true
    @State private var systemAudio = true
    @State private var webcam = true
    @State private var status = ""
    @State private var busy = false
    @AppStorage("recordingCameraUID") private var cameraUID = ""
    @AppStorage("microphoneUID") private var microphoneUID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Record something").font(MM.Fonts.title)
            Picker("Source", selection: $source) {
                Text("Screen or region").tag("region"); Text("Window").tag("window"); Text("Camera only").tag("camera")
            }.pickerStyle(.segmented).clickable()
            if source == "window" {
                Picker("Window", selection: $windowID) {
                    Text("Choose a window").tag("")
                    ForEach(windows, id: \.windowID) { Text(($0.owningApplication?.applicationName ?? "App") + " — " + ($0.title ?? "Window")).tag(String($0.windowID)) }
                }.clickable()
                Button("Refresh windows") { loadWindows() }.clickable()
            }
            Toggle("Microphone", isOn: $microphone).clickable()
            Picker("Input", selection: $microphoneUID) {
                Text("System default").tag("")
                ForEach(AVCaptureDevice.devices(for: .audio), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }.clickable().disabled(!microphone)
            if source != "camera" { Toggle("System audio", isOn: $systemAudio).clickable() }
            if source == "region" { Toggle("Camera bubble", isOn: $webcam).clickable() }
            if source == "camera" || source == "region" && webcam {
                Picker("Camera", selection: $cameraUID) {
                    Text("Default camera").tag("")
                    ForEach(AVCaptureDevice.devices(for: .video), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.clickable()
            }
            Text(source == "window" ? "Only the selected window is captured. The camera bubble is available with screen/region capture." : "Recordings are saved locally. Sharing is a separate action.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            if !status.isEmpty { Text(status).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.danger) }
            Spacer()
            HStack {
                Button("Cancel", action: dismiss).clickable()
                Spacer()
                Button(busy ? "Preparing…" : source == "region" ? "Choose area" : "Record") { start() }
                    .clickable().disabled(busy || source == "window" && windowID.isEmpty)
            }
        }.padding(MM.Layout.paddingLarge).font(MM.Fonts.body).background(MM.Colors.background)
            .onChange(of: source) { _, value in if value == "window", windows.isEmpty { loadWindows() } }
    }
    private func loadWindows() {
        Task {
            guard await CaptureEngine.shared.authorizeInteractively() else { status = "Allow screen recording to list windows."; return }
            do {
                windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows
                    .filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 40 && $0.frame.height > 40 }
                if !windows.contains(where: { String($0.windowID) == windowID }) { windowID = "" }
            } catch { status = error.localizedDescription }
        }
    }
    private func start() {
        busy = true
        Task {
            do {
                if source == "camera" { try await CameraOnlyRecorder.shared.start(microphone: microphone) }
                else if source == "window", #available(macOS 15.0, *) {
                    try await ScreenRecorder.shared.startForAgent(region: nil, windowID: windowID, maximumDuration: 3600, microphone: microphone, systemAudio: systemAudio)
                } else { ScreenRecorder.shared.startRegionFromPicker(microphone: microphone, systemAudio: systemAudio, webcam: webcam) }
                dismiss()
            } catch { status = error.localizedDescription; busy = false }
        }
    }
}

/// Video-only AVCaptureSession; all microphone audio uses the existing shared
/// NarrationTrack/AudioCapture pipeline. The camera driver owns its queue.
private final class CameraCaptureDriver: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.muckstack.myman.camera-recording")
    var onStart: (@Sendable () -> Void)?
    var onFinish: (@Sendable (URL, Error?) -> Void)?
    func start(device: AVCaptureDevice, url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw PersonalizationError.invalid("This camera cannot record video.") }
                    session.addInput(input); session.addOutput(output)
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    session.commitConfiguration(); session.startRunning()
                    output.maxRecordedDuration = CMTime(seconds: 3600, preferredTimescale: 600)
                    output.startRecording(to: url, recordingDelegate: self)
                    continuation.resume()
                } catch { session.commitConfiguration(); continuation.resume(throwing: error) }
            }
        }
    }
    func stop() { queue.async { [self] in output.stopRecording() } }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { onStart?() }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in session.stopRunning() }
        let succeeded = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        onFinish?(url, succeeded ? nil : error)
    }
}

@MainActor final class CameraOnlyRecorder: ObservableObject {
    static let shared = CameraOnlyRecorder()
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private var driver: CameraCaptureDriver?
    private let narration = NarrationTrack()
    private var panel: FloatingPanel?
    private var startedAt = Date()
    private var stopping = false
    private var narrationTask: Task<Void, Never>?
    func start(microphone: Bool) async throws {
        guard !isBusy, !ScreenRecorder.shared.isBusy else { throw PersonalizationError.invalid("Finish the current recording first.") }
        isBusy = true; stopping = false; status = "Starting camera…"
        do {
            guard await AVCaptureDevice.requestAccess(for: .video), let camera = RecordingDevices.camera else { throw PersonalizationError.invalid("Allow Camera access and connect a camera.") }
            if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw PersonalizationError.invalid("Allow Microphone access or turn the microphone off.") }
            guard !stopping, !Task.isCancelled else { throw CancellationError() }
            NotificationCenter.default.post(name: MeetingDetector.suppressNotification, object: nil)
            let url = SettingsStore.shared.screenshotFolderURL.appendingPathComponent("Camera-" + UUID().uuidString + ".mov")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let driver = CameraCaptureDriver(); self.driver = driver
            driver.onStart = { [weak self] in Task { @MainActor in
                guard let self else { return }
                if self.stopping { self.driver?.stop(); return }
                self.startedAt = Date(); self.status = "Camera recording"
                if microphone { self.narrationTask = Task { await self.narration.start(alongside: url, videoStartedAt: self.startedAt) } }
            } }
            driver.onFinish = { [weak self] url, error in Task { @MainActor in await self?.finish(url, error: error) } }
            try await driver.start(device: camera, url: url)
            if stopping { driver.stop(); return }
            let panel = FloatingPanel(content: CameraRecordingControls(recorder: self), fixedSize: true)
            panel.setContentSize(NSSize(width: 360, height: 110)); panel.dismissesOnResign = false
            panel.onCancel = { [weak self] in self?.stop() }
            self.panel = panel; panel.present()
        } catch { isBusy = false; driver = nil; throw error }
    }
    func stop() {
        guard isBusy, !stopping else { return }
        stopping = true; status = "Saving camera recording…"; driver?.stop()
    }
    private func finish(_ url: URL, error: Error?) async {
        _ = await narrationTask?.value
        let audio = narration.close()
        defer { isBusy = false; driver = nil; panel?.orderOut(nil); panel = nil; narrationTask = nil }
        do {
            if let error { throw error }
            let movie = try await ShareReadyMovie.finalize(movie: url, narration: audio?.wavURL, narrationOffsetSeconds: audio?.offsetSeconds ?? 0)
            let duration = try await AVURLAsset(url: movie).load(.duration).seconds
            let record = ScreenRecording(id: UUID().uuidString, path: movie.path, duration: Int(ceil(duration)), createdAt: startedAt)
            try await Database.shared.write { try record.insert($0) }
            Brain.syncRecording(id: record.id, filePath: record.path, duration: record.duration, transcript: "", createdAt: record.createdAt)
            ScreenRecorder.shared.transcribeAndSync(record)
            Toast.show("Camera recording saved", actionLabel: "Edit", action: { RecordingPolishController.shared.open(movie: movie) })
        } catch { Toast.show("Camera recording needs recovery. Original files were kept.", actionLabel: "Show", action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }, duration: 12) }
    }
}

private struct CameraRecordingControls: View {
    @ObservedObject var recorder: CameraOnlyRecorder
    var body: some View {
        VStack(spacing: MM.Layout.spacing) {
            Text(recorder.status).font(MM.Fonts.body)
            Button("Stop and save") { recorder.stop() }.clickable()
        }.padding(MM.Layout.paddingLarge).frame(maxWidth: .infinity, maxHeight: .infinity).background(MM.Colors.background)
    }
}
