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

/// The one camera control on the recording bar. "No camera" hides the bubble; picking a camera shows it.
/// The choice is saved, so the next recording starts with it.
struct CameraMenu: View {
    var allowed = true
    @ObservedObject private var bubble = WebcamBubble.shared
    @AppStorage("mm.webcamBubble") private var bubbleWanted = true
    @State private var devices: [AVCaptureDevice] = []
    @State private var selected = ""

    static let off = "__off__"

    var body: some View {
        Menu {
            Picker("Camera", selection: $selected) {
                Text("No camera").tag(Self.off)
                Text("Automatic").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: bubble.isOn ? "video" : "video.slash")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(bubble.isOn ? MM.Colors.textPrimary : MM.Colors.danger)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!allowed)
        .help(!allowed ? "Camera is unavailable for window recordings" : "Choose the camera, or No camera")
        .accessibilityLabel("Choose the camera")
        .onAppear {
            devices = CameraSelection.available()
            selected = bubbleWanted ? CameraSelection.savedUID() : Self.off
        }
        .onChange(of: selected) { _, uid in
            if uid == Self.off {
                bubbleWanted = false
                WebcamBubble.shared.turnOff()
            } else {
                CameraSelection.save(uid)
                bubbleWanted = true
                if bubble.isOn { WebcamBubble.shared.switchCamera() } else { WebcamBubble.shared.turnOn() }
            }
        }
    }
}

/// The microphone the next recording uses. The same saved input as dictation. Mute stays on the button beside it.
struct MicrophoneMenu: View {
    @AppStorage("microphoneUID") private var microphoneUID = ""
    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        Menu {
            Picker("Microphone", selection: $microphoneUID) {
                Text("System default").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MM.Colors.textSecondary)
                .frame(width: 14, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the microphone (applies to the next recording)")
        .accessibilityLabel("Choose the microphone")
        .onAppear { devices = AVCaptureDevice.devices(for: .audio) }
    }
}

/// The color of the frame drawn around a region recording, and the Polish backdrop. Blue by default.
enum RecordingFrameStyle {
    static let key = "recordingFrameRGB"
    static let changed = Notification.Name("mm.recordingFrameColorChanged")

    static func color(_ defaults: UserDefaults = .standard) -> NSColor {
        if let rgb = defaults.array(forKey: key) as? [Double], rgb.count == 3 {
            return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        return NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue
    }

    static func save(_ color: NSColor, _ defaults: UserDefaults = .standard) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        defaults.set([Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)], forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
