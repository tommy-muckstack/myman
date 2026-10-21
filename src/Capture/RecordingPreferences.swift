import AVFoundation
import SwiftUI

enum RecordingSource: String, CaseIterable, Identifiable {
    case region, window, camera
    var id: String { rawValue }
    var label: String {
        switch self {
        case .region: "Screen or region"
        case .window: "Window"
        case .camera: "Camera only"
        }
    }
}

/// Read a fresh snapshot for each recording. Existing microphone and camera
/// choices keep their keys, including choices made on the recording controls.
struct RecordingPreferences {
    let source: RecordingSource
    let microphone: Bool
    let systemAudio: Bool
    let webcam: Bool

    init(defaults: UserDefaults = .standard) {
        source = RecordingSource(rawValue: defaults.string(forKey: "recordingSource") ?? "") ?? .region
        microphone = defaults.object(forKey: "mm.screenRecordingMicrophone") as? Bool ?? true
        systemAudio = defaults.object(forKey: "mm.screenRecordingSystemAudio") as? Bool ?? true
        webcam = defaults.object(forKey: "mm.webcamBubble") as? Bool ?? true
    }
}

struct RecordingSettingsView: View {
    @AppStorage("recordingSource") private var source = RecordingSource.region
    @AppStorage("mm.screenRecordingMicrophone") private var microphone = true
    @AppStorage("mm.screenRecordingSystemAudio") private var systemAudio = true
    @AppStorage("mm.webcamBubble") private var webcam = true
    @AppStorage("microphoneUID") private var microphoneUID = ""
    @AppStorage("recordingCameraUID") private var cameraUID = ""
    @State private var microphones: [AVCaptureDevice] = []
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Picker("Source", selection: $source) {
                ForEach(RecordingSource.allCases) { Text($0.label).tag($0) }
            }.clickable()
            Text(source == .region ? "Record opens area selection immediately. Drag an area, then recording starts after a three-second countdown." : source == .window ? "Record asks which window to capture, using these saved audio settings." : "Record starts your camera using these saved settings.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Microphone", isOn: $microphone).clickable()
            Picker("Input", selection: $microphoneUID) {
                Text("System default").tag("")
                ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                if !microphoneUID.isEmpty, !microphones.contains(where: { $0.uniqueID == microphoneUID }) {
                    Text("Saved microphone unavailable").tag(microphoneUID)
                }
            }.clickable().disabled(!microphone)
            Toggle("System audio", isOn: $systemAudio).clickable().disabled(source == .camera)
            Toggle("Camera bubble", isOn: $webcam).clickable().disabled(source != .region)
            Picker("Camera", selection: $cameraUID) {
                Text("Default camera").tag("")
                ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                if !cameraUID.isEmpty, !cameras.contains(where: { $0.uniqueID == cameraUID }) {
                    Text("Saved camera unavailable").tag(cameraUID)
                }
            }.clickable().disabled(source != .camera && (source != .region || !webcam))
            Text("Changes apply to your next recording. The microphone input is also used for dictation. Unavailable devices fall back to the system default.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(MM.Fonts.body)
        .toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
        .task {
            microphones = AVCaptureDevice.devices(for: .audio)
            cameras = AVCaptureDevice.devices(for: .video)
        }
    }
}
