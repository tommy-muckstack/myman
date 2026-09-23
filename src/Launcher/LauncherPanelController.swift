import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController {
    private var panel: FloatingPanel?
    private var adaptiveVoice: AdaptiveLauncherVoice?
    private let makeActions: () -> [LauncherAction]
    private let saveQueryAsNote: (String) -> Void

    init(actions: @escaping () -> [LauncherAction], saveQueryAsNote: @escaping (String) -> Void) {
        self.makeActions = actions
        self.saveQueryAsNote = saveQueryAsNote
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible {
            panel.dismiss()
        } else {
            show()
        }
    }

    /// Open without the toggle's close-if-open behavior (⌘Tab activation
    /// must never dismiss a launcher that's already up).
    func open() {
        if !isVisible { show() }
    }

    private func show() {
        Analytics.track("launcher_opened")
        panel?.dismiss()
        adaptiveVoice?.stop()
        let voice = AdaptiveLauncherVoice()
        adaptiveVoice = voice
        // The tools menu expands inline in the standard launcher.
        let quickTools = LauncherAction(id: "quick_tools", icon: .agent, title: "Quick Tools", hint: nil, enabled: true) {}
        let content = AdaptiveLauncherView(
            actions: makeActions() + [quickTools],
            voice: voice,
            onSaveQueryAsNote: { [weak self] text in self?.saveQueryAsNote(text) },
            onDismiss: { [weak self] in self?.panel?.dismiss() },
            onSizeChange: { [weak self] size in self?.applyContentSize(size) }
        )
        let launcherPanel = FloatingPanel(content: content, fixedSize: true)
        launcherPanel.isMovable = false
        launcherPanel.onDismiss = { [weak self] in
            self?.adaptiveVoice?.stop()
        }
        panel = launcherPanel
        launcherPanel.present()
        if let screen = launcherPanel.screen {
            let visible = screen.visibleFrame
            let size = launcherPanel.frame.size
            // Position the compact launcher by its top edge. Centering the
            // expanded history used to push the search field to the screen top.
            let top = visible.minY + visible.height * 0.72
            launcherPanel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                y: max(visible.minY + 16, top - size.height)))
        }
        if launcherPanel.isVisible { adaptiveVoice?.startAutomatically() }
    }

    /// Resize to fit new content, keeping the panel's TOP edge fixed so the
    /// recents list unfolds downward instead of the whole panel jumping.
    /// Resize to the size SwiftUI reports it rendered, keeping the TOP edge
    /// fixed so recents unfold downward.
    private var latestContentSize: CGSize = .zero

    private func applyContentSize(_ size: CGSize) {
        // Deferred out of the layout pass, and COALESCED: only the newest
        // reported size ever applies — queued stale sizes were re-applying
        // out of order and made the search bar jitter on hover.
        guard size.width.isFinite, size.height.isFinite, size.height > 1 else { return }
        latestContentSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let size = self.latestContentSize
            guard size.height > 1 else { return }
            guard abs(panel.frame.height - size.height) > 0.5
                || abs(panel.frame.width - size.width) > 0.5 else { return }
            let visible = panel.screen?.visibleFrame ?? panel.frame
            let top = min(visible.maxY - 16, max(panel.frame.maxY, visible.minY + size.height + 16))
            // Instant: the window is the anchor. All motion lives in the rows.
            panel.setFrame(
                NSRect(x: panel.frame.minX, y: top - size.height,
                       width: size.width, height: size.height),
                display: true
            )

        }
    }

}
