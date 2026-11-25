import AppKit
import SwiftUI

/// The small pill shown while a narration take runs: state, elapsed and remaining time, and the take controls.
/// It never takes focus from the page being narrated, and it is excluded from screen capture, so it never shows up in a recording.
@MainActor
enum NarrationControlPanel {
    private static var panel: NSPanel?
    /// Takes longer than this ask before they are thrown away.
    static let confirmAboveMs = 5_000

    static func show(recorder: NarrationRecorder) {
        close()
        let host = NSHostingView(rootView: NarrationControlView(recorder: recorder))
        let size = NSSize(width: 420, height: 56)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 96))
        }
        window.orderFrontRegardless()
        panel = window
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Asks before a take longer than five seconds is thrown away. Shorter takes go without asking.
    static func confirmDiscard(_ verb: String, elapsedMs: Int) -> Bool {
        guard elapsedMs >= confirmAboveMs else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(verb) this take?"
        alert.informativeText = "The recording so far will be thrown away."
        alert.alertStyle = .warning
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Keep recording")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct NarrationControlView: View {
    @ObservedObject var recorder: NarrationRecorder

    private var isPaused: Bool { recorder.phase == .paused }
    private var isCounting: Bool { if case .countingDown = recorder.phase { return true } else { return false } }
    /// Amber once the take reaches four minutes thirty, close to the five-minute cap.
    private var nearCap: Bool { recorder.elapsedMs >= 270_000 }

    private var stateText: String {
        switch recorder.phase {
        case .countingDown(let count): return "Starting in \(count)"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finishing: return "Saving"
        case .idle: return "Ready"
        }
    }

    private func clock(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isPaused ? MM.Colors.textTertiary : Color.red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(stateText).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
                Text("\(clock(recorder.elapsedMs)) of 5:00")
                    .font(MM.Fonts.metadata).monospacedDigit()
                    .foregroundStyle(nearCap ? Color.orange : MM.Colors.textSecondary)
            }
            .frame(minWidth: 96, alignment: .leading)
            Spacer(minLength: 0)
            pill(isPaused ? "Resume" : "Pause", enabled: recorder.phase == .recording || isPaused) {
                if isPaused { try? recorder.resume() } else { try? recorder.pause() }
            }
            pill("Stop & save", enabled: recorder.phase != .finishing, prominent: true) {
                Task { _ = try? await recorder.stop() }
            }
            pill("Restart", enabled: (recorder.phase == .recording || isPaused) && !isCounting) {
                guard NarrationControlPanel.confirmDiscard("Restart", elapsedMs: recorder.elapsedMs) else { return }
                Task { _ = try? await recorder.restart() }
            }
            pill("Cancel", enabled: recorder.phase != .finishing) {
                guard NarrationControlPanel.confirmDiscard("Discard", elapsedMs: recorder.elapsedMs) else { return }
                Task { await recorder.cancelTake() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(MM.Colors.border, lineWidth: 1))
        )
        .padding(4)
    }

    private func pill(_ title: String, enabled: Bool, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MM.Fonts.metadata)
                .foregroundStyle(prominent ? MM.Colors.background : MM.Colors.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(prominent ? MM.Colors.textPrimary : MM.Colors.surface))
                .clickable(minSize: 24)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
