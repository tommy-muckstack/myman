import AppKit
import Sparkle
import SwiftUI

/// Keeps a downloaded update visible without interrupting capture work.
@MainActor
final class AppUpdateCoordinator: NSObject, SPUUpdaterDelegate {
    typealias Presenter = (String, @escaping () -> Void, @escaping () -> Void) -> Void
    private let isBusy: () -> Bool
    private let present: Presenter
    private let dismiss: () -> Void
    private var timer: Timer?
    private var install: (() -> Void)?
    private var deferredRelaunch: (() -> Void)?
    private var version = ""
    private var remindAfter = Date.distantPast
    private var isPresented = false
    private(set) var isRestarting = false

    init(isBusy: @escaping () -> Bool,
         present: Presenter? = nil,
         dismiss: (() -> Void)? = nil) {
        self.isBusy = isBusy
        self.present = present ?? { UpdateReadyPrompt.show(version: $0, install: $1, later: $2) }
        self.dismiss = dismiss ?? { UpdateReadyPrompt.dismiss() }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }

    func updateReady(version: String, install: @escaping () -> Void) {
        hidePrompt()
        self.version = version
        self.install = install
        remindAfter = .distantPast
        isRestarting = false
        refresh()
    }

    func refresh(now: Date = Date()) {
        guard !isBusy() else { hidePrompt(); return }
        if let resume = deferredRelaunch {
            deferredRelaunch = nil
            resume()
            return
        }
        guard install != nil, !isRestarting, !isPresented, now >= remindAfter else { return }
        isPresented = true
        present(version, { [weak self] in self?.requestInstall() }, { [weak self] in self?.remindLater() })
    }

    func requestInstall() {
        guard !isRestarting, let install else { return }
        hidePrompt()
        // Recording may have started since the prompt was shown.
        guard !isBusy() else { return }
        isRestarting = true
        install()
    }

    func remindLater(now: Date = Date()) {
        remindAfter = now.addingTimeInterval(3600)
        hidePrompt()
    }

    func postponeRelaunch(until resume: @escaping () -> Void) -> Bool {
        isRestarting = true
        hidePrompt()
        guard isBusy() else { return false }
        deferredRelaunch = resume
        return true
    }

    /// Final gate for the race between Sparkle's relaunch callback and the
    /// actual AppKit termination request. Sparkle supports retrying its handler.
    func shouldCancelTermination() -> Bool {
        guard isRestarting, isBusy() else { return false }
        isRestarting = false
        deferredRelaunch = nil
        remindAfter = .distantPast
        return true
    }

    func clear() {
        install = nil
        deferredRelaunch = nil
        isRestarting = false
        hidePrompt()
    }

    private func hidePrompt() {
        guard isPresented else { return }
        isPresented = false
        dismiss()
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if MainActor.assumeIsolated({ isBusy() }) {
            throw NSError(domain: "com.muckstack.myman", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recording or transcription in progress — update deferred"])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            updateReady(version: item.displayVersionString, install: immediateInstallHandler)
        }
        // Keep Sparkle's ready-to-install handler; install-on-normal-quit is
        // still supported. No restart happens until the user chooses it.
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                            untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { postponeRelaunch(until: installHandler) }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { isRestarting = true }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated { clear() }
    }
}

@MainActor
private enum UpdateReadyPrompt {
    private static var panel: FloatingPanel?

    static func show(version: String, install: @escaping () -> Void, later: @escaping () -> Void) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let view = UpdateReadyView(version: version, install: install, later: later)
        let window = FloatingPanel(content: view, becomesKey: false, fixedSize: true)
        window.dismissesOnResign = false
        window.onCancel = later
        let size = NSSize(width: 380, height: 112)
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.maxX - size.width - MM.Layout.paddingLarge,
                               y: visible.minY + MM.Layout.paddingLarge,
                               width: size.width, height: size.height), display: true)
        panel = window
        window.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "My Man \(version) is ready to update.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct UpdateReadyView: View {
    let version: String
    var install: () -> Void
    var later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.padding) {
            Text("My Man \(version) is ready")
                .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
            HStack {
                Button("Later", action: later)
                    .buttonStyle(.plain).foregroundStyle(MM.Colors.textSecondary).clickable()
                Spacer()
                Button("Update & Restart", action: install)
                    .buttonStyle(.plain).foregroundStyle(MM.Colors.background)
                    .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                    .background(Capsule().fill(MM.Colors.textPrimary)).clickable()
            }.font(MM.Fonts.secondary)
        }
        .padding(MM.Layout.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: MM.Layout.radius).fill(MM.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border, lineWidth: 1))
    }
}
