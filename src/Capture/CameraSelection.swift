import AVFoundation
import SwiftUI

/// The camera a recording uses. One saved choice serves the webcam bubble, narration and the recording bar.
/// Nothing is hardcoded: the list is whatever macOS reports right now (Continuity Camera, USB, built-in).
enum CameraSelection {
    static let key = "recordingCameraUID"

    /// Every camera macOS can use right now. External ones (an iPhone, USB) come first.
    static func available() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ device: AVCaptureDevice) -> Int {
        if device.isContinuityCamera || device.deviceType == .continuityCamera || device.deviceType == .external { return 0 }
        if device.position != .front { return 1 }
        return 2
    }

    static func savedUID(_ defaults: UserDefaults = .standard) -> String { defaults.string(forKey: key) ?? "" }

    static func save(_ uid: String, _ defaults: UserDefaults = .standard) { defaults.set(uid, forKey: key) }

    /// The saved camera, if it is still connected. Empty means "automatic".
    static func selectedDevice(_ defaults: UserDefaults = .standard) -> AVCaptureDevice? {
        let uid = savedUID(defaults)
        guard !uid.isEmpty else { return nil }
        return available().first { $0.uniqueID == uid }
    }
}

/// A camera picker for the recording bar. Changing it switches the webcam bubble live.
struct CameraMenu: View {
    @State private var devices: [AVCaptureDevice] = []
    @State private var selected = CameraSelection.savedUID()

    var body: some View {
        Menu {
            Picker("Camera", selection: $selected) {
                Text("Automatic").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "video")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MM.Colors.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the camera")
        .accessibilityLabel("Choose the camera")
        .onAppear { devices = CameraSelection.available() }
        .onChange(of: selected) { _, uid in
            CameraSelection.save(uid)
            WebcamBubble.shared.switchCamera()
        }
    }
}
