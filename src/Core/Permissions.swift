import AppKit
import AVFoundation
import EventKit
import SwiftUI

// The permissions checklist — the one place every macOS access grant is
// visible, requestable, and verifiable. macOS shows each permission prompt
// ONCE per app ever; after that, requests silently no-op. Every row therefore
// prompts when it can and deep-links to the exact Settings pane when it
// can't, and a poll flips rows green the moment access lands — no relaunch,
// no dead buttons.

enum Permission: String, CaseIterable, Identifiable {
    case microphone, screenRecording, camera, calendar, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .calendar: "Calendar"
        case .accessibility: "Auto-Paste"
        }
    }

    var detail: String {
        switch self {
        case .microphone: "Dictation and your side of meetings"
        case .screenRecording: "Screenshots & recordings"
        case .camera: "Webcam bubble in screen recordings"
        case .calendar: "Your schedule and meeting names"
        case .accessibility: "Types dictation into any app"
        }
    }

    var icon: MMIcon {
        switch self {
        case .microphone: .mic
        case .screenRecording: .screenshot
        case .camera: .camera
        case .calendar: .calendar
        case .accessibility: .write
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .camera:
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .calendar:
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .accessibility:
            AXIsProcessTrusted()
        }
    }

    private var settingsPane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .calendar: "Privacy_Calendars"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    private func openSettingsPane() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompt if macOS still allows it; otherwise land the user on the exact
    /// Settings pane. Always visibly does something.
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettingsPane()
            }
        case .screenRecording:
            // No notDetermined API — CGRequest prompts once ever, then only
            // registers the app in the pane. Ask once, then deep-link.
            let asked = UserDefaults.standard.bool(forKey: "mm.askedScreenRecording")
            if !asked {
                UserDefaults.standard.set(true, forKey: "mm.askedScreenRecording")
                CGRequestScreenCaptureAccess()
            } else {
                openSettingsPane()
            }
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            } else {
                openSettingsPane()
            }
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                EKEventStore().requestFullAccessToEvents { _, _ in }
            } else {
                openSettingsPane()
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                openSettingsPane()
            }
        }
    }
}

extension Notification.Name {
    /// Posted whenever the checklist observes a permission flip to granted —
    /// lets services (CalendarWatcher) activate without a relaunch.
    static let mmPermissionsChanged = Notification.Name("mm.permissionsChanged")
}

struct PermissionsChecklist: View {
    @State private var granted: Set<Permission> = []
    @State private var poll: Timer?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Permission.allCases) { permission in
                row(permission)
            }
        }
        .onAppear {
            refresh()
            // Live poll: rows flip green the moment access lands in TCC.
            poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                DispatchQueue.main.async { refresh() }
            }
        }
        .onDisappear {
            poll?.invalidate()
            poll = nil
        }
    }

    private func refresh() {
        let now = Set(Permission.allCases.filter(\.isGranted))
        if now != granted {
            let newlyGranted = !now.subtracting(granted).isEmpty
            granted = now
            if newlyGranted {
                NotificationCenter.default.post(name: .mmPermissionsChanged, object: nil)
            }
        }
    }

    private func row(_ permission: Permission) -> some View {
        let isGranted = granted.contains(permission)
        return HStack(spacing: 10) {
            IconView(icon: permission.icon, size: 15,
                     color: isGranted ? MM.Colors.textTertiary : MM.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                Text(permission.detail)
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textTertiary)
            }
            Spacer()
            if isGranted {
                Text("✓")
                    .font(MM.Fonts.body)
                    .foregroundStyle(Color.green.opacity(0.85))
                    .frame(minWidth: 52)
            } else {
                Button {
                    permission.request()
                } label: {
                    Text("Allow")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(MM.Colors.textPrimary))
                        .clickable(minSize: 26)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(MM.Colors.surface.opacity(isGranted ? 0.45 : 1))
        )
    }
}
