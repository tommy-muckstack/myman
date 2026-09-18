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
    private let blockingReason: () -> String
    private let canCancelRecording: () -> Bool
    private let manageRecording: () -> Void
    private let presentBlocked: (String, String, Bool, @escaping () -> Void, @escaping () -> Void) -> Void
    private var blockedReason: String?
    private var timer: Timer?
    private var install: (() -> Void)?
    private var deferredRelaunch: (() -> Void)?
    private var version = ""
    private var remindAfter = Date.distantPast
    private var isPresented = false
    private(set) var isRestarting = false

    init(isBusy: @escaping () -> Bool,
         present: Presenter? = nil,
         dismiss: (() -> Void)? = nil,
         blockingReason: @escaping () -> String = { "Work is still in progress." },
         canCancelRecording: @escaping () -> Bool = { false },
         manageRecording: @escaping () -> Void = {},
         presentBlocked: ((String, String, Bool, @escaping () -> Void, @escaping () -> Void) -> Void)? = nil) {
        self.isBusy = isBusy
        self.blockingReason = blockingReason
        self.canCancelRecording = canCancelRecording
        self.manageRecording = manageRecording
        self.presentBlocked = presentBlocked ?? { version, reason, canCancel, manage, later in
            UpdateReadyPrompt.showBlocked(version: version, reason: reason, canCancel: canCancel, manage: manage, later: later)
        }
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

    func stopMonitoring() {
        timer?.invalidate(); timer = nil
        clear()
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
        if isBusy() {
            guard install != nil, now >= remindAfter else { hidePrompt(); return }
            let reason = blockingReason()
            let key = reason + String(canCancelRecording())
            guard blockedReason != key else { return }
            hidePrompt()
            isPresented = true
            blockedReason = key
            presentBlocked(version, reason, canCancelRecording(), { [weak self] in
                guard let self, self.install != nil, self.isPresented, self.blockedReason == key else { return }
                self.manageRecording()
                self.refresh()
            }, { [weak self] in self?.remindLater() })
            return
        }
        if blockedReason != nil { hidePrompt() }
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
        guard !isBusy() else { refresh(); return }
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

    func clear() {
        install = nil
        deferredRelaunch = nil
        isRestarting = false
        hidePrompt()
    }

    private func hidePrompt() {
        guard isPresented else { return }
        isPresented = false
        blockedReason = nil
        dismiss()
    }

    // Checking/downloading updates never interrupts recording. Only the
    // install/relaunch callbacks below protect active work; blocking checks
    // produced a dead-end "recording" error even for completed dictation.

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

    static func showBlocked(version: String, reason: String, canCancel: Bool,
                            manage: @escaping () -> Void, later: @escaping () -> Void) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let view = UpdateBlockedView(version: version, reason: reason, canCancel: canCancel, manage: manage, later: later)
        let window = FloatingPanel(content: view, becomesKey: true, fixedSize: true)
        window.dismissesOnResign = false
        window.onCancel = later
        let size = NSSize(width: 420, height: 180)
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.maxX - size.width - MM.Layout.paddingLarge,
                               y: visible.minY + MM.Layout.paddingLarge,
                               width: size.width, height: size.height), display: true)
        panel = window
        window.orderFrontRegardless()
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

struct UpdateBlockedView: View {
    let version: String
    let reason: String
    let canCancel: Bool
    var manage: () -> Void
    var later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.padding) {
            Text("My Man \(version) is ready")
                .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
            Text(reason + ". Updates can download now; restart waits until this finishes.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later", action: later).buttonStyle(.plain).clickable()
                Spacer()
                Button(canCancel ? "Cancel Recording…" : "Workflows & Recovery…", action: manage)
                    .buttonStyle(.plain).clickable()
            }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
        }
        .padding(MM.Layout.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: MM.Layout.radius).fill(MM.Colors.background))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border, lineWidth: 1))
    }
}

struct AppUpdateActivity {
    let reasons: [String]
    let canCancelRecording: Bool
    var isBusy: Bool { !reasons.isEmpty }
    var description: String { reasons.joined(separator: " · ") }

    init(voice: VoiceController.Phase, voiceStarting: Bool = false,
         meetingStarting: Bool = false, meetingRecording: Bool = false, meetingProcessing: Bool = false,
         screenBusy: Bool = false, screenRecording: Bool = false, screenProcessing: Bool = false, screenSelecting: Bool = false,
         notesProcessing: Bool = false) {
        var reasons: [String] = []
        var canCancel = meetingRecording || screenRecording || screenSelecting
        switch voice {
        case .idle, .done: if voiceStarting { reasons.append("Starting dictation") }
        case .recording: reasons.append("Dictation is recording"); canCancel = true
        case .preparing: reasons.append("Preparing dictation")
        case .transcribing: reasons.append("Transcribing dictation")
        }
        if meetingRecording { reasons.append("A meeting is recording") }
        else if meetingStarting { reasons.append("Starting a meeting recording") }
        if meetingProcessing { reasons.append("Transcribing a saved meeting") }
        if screenRecording { reasons.append("A screen recording is active") }
        else if screenBusy { reasons.append("Preparing or saving a screen recording") }
        if screenProcessing { reasons.append("Transcribing a saved screen recording") }
        if notesProcessing { reasons.append("Generating meeting notes") }
        self.reasons = reasons
        canCancelRecording = canCancel
    }

    @MainActor static func current(voice: VoiceController, meetings: MeetingController) -> Self {
        Self(voice: voice.phase, voiceStarting: voice.starting,
             meetingStarting: meetings.isStarting, meetingRecording: meetings.phase != .idle,
             meetingProcessing: meetings.isTranscribing,
             screenBusy: ScreenRecorder.shared.isBusy, screenRecording: ScreenRecorder.shared.isRecording,
             screenProcessing: ScreenRecorder.shared.isTranscribing, screenSelecting: ScreenRecorder.shared.hasPendingSelection,
             notesProcessing: !MeetingNotesService.shared.stages.isEmpty)
    }
}
