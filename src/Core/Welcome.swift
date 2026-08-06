import AppKit
import SwiftUI

// First-launch welcome. My Man is a menu-bar app with no window and no Dock
// icon — a fresh install looks like "nothing happened" without this. Shown
// exactly once, centered, and it teaches the three hotkeys that matter.

@MainActor
final class WelcomeController {
    static let shared = WelcomeController()
    private var panel: FloatingPanel?
    private static let flag = "mm.hasSeenWelcome"

    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.flag) else { return }
        UserDefaults.standard.set(true, forKey: Self.flag)
        Analytics.track("welcome_shown")
        show()
    }

    func show() {
        panel?.orderOut(nil)
        let view = WelcomeView(onDone: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        })
        let welcomePanel = FloatingPanel(content: view, becomesKey: true)
        welcomePanel.onDismiss = { [weak self] in self?.panel = nil }
        panel = welcomePanel
        welcomePanel.layoutIfNeeded()
        guard let screen = NSScreen.main else { return }
        let size = welcomePanel.contentIdeal
        let visible = screen.visibleFrame
        welcomePanel.setFrame(
            NSRect(x: visible.midX - size.width / 2,
                   y: visible.midY - size.height / 2 + 40,
                   width: size.width, height: size.height),
            display: true
        )
        welcomePanel.orderFrontRegardless()
        welcomePanel.makeKey()
    }
}

private struct WelcomeView: View {
    var onDone: () -> Void
    private let settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .padding(.top, 28)
            }
            Text("My Man is ready")
                .font(MM.Fonts.title)
                .foregroundStyle(MM.Colors.textPrimary)
                .padding(.top, 14)
            Text("It lives in your Dock and menu bar.\nEverything is a hotkey away:")
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(spacing: 10) {
                hotkeyRow(icon: .search, label: "Search, tasks & calendar",
                          hint: settings.hint(for: .launcher))
                hotkeyRow(icon: .mic, label: "Dictate anywhere",
                          hint: settings.hint(for: .voice))
                hotkeyRow(icon: .screenshot, label: "Screenshot & annotate",
                          hint: settings.hint(for: .screenshot))
                hotkeyRow(icon: .calendar, label: "Record a meeting",
                          hint: settings.hint(for: .meeting))
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Text("Give My Man access")
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
            PermissionsChecklist()
                .padding(.horizontal, 28)
                .padding(.top, 8)

            Button {
                onDone()
            } label: {
                Text("Get started")
                    .font(MM.Fonts.body)
                    .foregroundStyle(MM.Colors.background)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(MM.Colors.textPrimary))
                    .clickable(minSize: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MM.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(MM.Colors.border, lineWidth: 1))
        )
    }

    private func hotkeyRow(icon: MMIcon, label: String, hint: String) -> some View {
        HStack(spacing: 10) {
            IconView(icon: icon, size: 15, color: MM.Colors.textSecondary)
            Text(label)
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textPrimary)
            Spacer()
            Text(hint)
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(MM.Colors.surface))
        }
    }
}
