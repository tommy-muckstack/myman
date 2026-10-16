import SwiftUI

struct RecordingControlBar: View {
    var elapsed: String
    var isPaused = false
    var isStopping = false
    var allowsWebcam = true
    var webcamOn = false
    var microphoneEnabled = true
    var microphoneLevel: CGFloat = 0
    var onCamera: () -> Void
    var onMicrophone: () -> Void
    var onStop: () -> Void
    var onRestart: () -> Void

    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            if isStopping {
                ProgressView().controlSize(.small)
                Text("Saving recording…").font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
            } else {
                IconView(icon: .recordScreen, size: 14, color: MM.Colors.danger)
                Text(isPaused ? "Paused" : elapsed)
                    .font(MM.Fonts.secondary.monospacedDigit())
                    .foregroundStyle(MM.Colors.textSecondary)
                    .frame(minWidth: 42, alignment: .leading)
                Button(action: onCamera) {
                    IconView(icon: webcamOn ? .recordScreen : .cameraOff, size: 14,
                             color: webcamOn ? MM.Colors.textPrimary : MM.Colors.danger)
                        .clickable(minSize: 32)
                }.buttonStyle(.plain).disabled(!allowsWebcam)
                    .help(!allowsWebcam ? "Webcam is unavailable for window recordings" : webcamOn ? "Hide camera" : "Show camera")
                    .accessibilityLabel(webcamOn ? "Hide camera" : "Show camera")
                Button(action: onMicrophone) {
                    IconView(icon: microphoneEnabled ? .mic : .micOff, size: 16,
                             color: microphoneEnabled ? (microphoneLevel > 0.035 ? MM.Colors.accent : MM.Colors.textPrimary) : MM.Colors.danger)
                        .clickable(minSize: 32)
                }.buttonStyle(.plain)
                    .help(microphoneEnabled ? "Mute microphone" : "Include microphone")
                    .accessibilityLabel(microphoneEnabled ? "Mute microphone" : "Include microphone")
                Button(action: onStop) {
                    Text("Stop").font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background)
                        .padding(.horizontal, MM.Layout.spacing)
                        .frame(height: 30)
                        .background(Capsule().fill(MM.Colors.textPrimary))
                        .fixedSize().clickable(minSize: 32)
                }.buttonStyle(.plain).accessibilityIdentifier("recording-stop")
                Button("Restart", action: onRestart)
                    .buttonStyle(.plain).font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary).clickable(minSize: 32)
                    .help("Discard this take and record again")
            }
        }
        .padding(.horizontal, MM.Layout.spacing)
        .frame(width: RecordingControlPlacement.size.width, height: RecordingControlPlacement.size.height)
        .background(Capsule().fill(MM.Colors.background)
            .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1)))
    }
}
