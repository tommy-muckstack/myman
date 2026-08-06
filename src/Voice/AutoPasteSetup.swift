import AppKit
import SwiftUI

// The auto-paste ask, made unmissable: a centered card that explains the one
// missing grant, opens the exact Settings pane, and watches live — the moment
// the toggle flips, it turns green and leaves. macOS gives Accessibility no
// native Allow button, so this guided moment is the best flow possible.

@MainActor
final class AutoPasteSetupController: ObservableObject {
    static let shared = AutoPasteSetupController()

    @Published var granted = false
    private var panel: FloatingPanel?
    private var pollTimer: Timer?

    /// Show after a dictation lands clipboard-only. No-op if already granted.
    func showIfNeeded() {
        guard !AXIsProcessTrusted(), panel == nil else { return }
        granted = false
        let card = FloatingPanel(content: AutoPasteSetupView(
            controller: self,
            onOpenSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            onDismiss: { [weak self] in self?.close() }
        ))
        card.onDismiss = { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.panel = nil
        }
        panel = card
        card.present()

        // Watch for the toggle flipping while Settings is open.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, AXIsProcessTrusted() else { return }
                self.granted = true
                Analytics.track("auto_paste_enabled")
                try? await Task.sleep(for: .seconds(1.6))
                self.close()
            }
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct AutoPasteSetupView: View {
    @ObservedObject var controller: AutoPasteSetupController
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if controller.granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("Auto-paste is on")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Text("Dictation now types itself wherever your cursor is.")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
            } else {
                IconView(icon: .write, size: 30, color: MM.Colors.accent)
                Text("One switch away from auto-paste")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Text("Your dictation was copied — but with Accessibility on, My Man types it straight into whatever you're working in. macOS requires you to flip this one yourself:\nfind “My Man” in the list and turn it on.")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onOpenSettings) {
                    Text("Open Accessibility Settings")
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.background)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(MM.Colors.textPrimary))
                }
                .buttonStyle(.plain)

                Text("I'm watching — this card closes itself once you flip it.")
                    .font(MM.Fonts.hint)
                    .foregroundStyle(MM.Colors.textTertiary)

                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
        )
        .animation(MM.Motion.elastic, value: controller.granted)
    }
}
