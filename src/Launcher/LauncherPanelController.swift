import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController {
    private var panel: FloatingPanel?
    private var tasksPanel: FloatingPanel?
    private var calendarPanel: FloatingPanel?
    private let makeActions: () -> [LauncherAction]
    private let openNote: (Note) -> Void
    private let openScreenshot: (URL) -> Void
    private let saveQueryAsNote: (String) -> Void

    init(actions: @escaping () -> [LauncherAction],
         openNote: @escaping (Note) -> Void,
         openScreenshot: @escaping (URL) -> Void,
         saveQueryAsNote: @escaping (String) -> Void) {
        self.makeActions = actions
        self.openNote = openNote
        self.openScreenshot = openScreenshot
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
        // Rebuilt per show so the action list always reflects current state.
        let view = LauncherView(
            actions: makeActions(),
            onOpenNote: { [weak self] note in self?.openNote(note) },
            onOpenScreenshot: { [weak self] url in self?.openScreenshot(url) },
            onSaveQueryAsNote: { [weak self] text in self?.saveQueryAsNote(text) },
            onDismiss: { [weak self] in self?.panel?.dismiss() },
            onSizeChange: { [weak self] size in self?.applyContentSize(size) }
        )
        panel?.dismiss()
        let launcherPanel = FloatingPanel(content: view, fixedSize: true)
        launcherPanel.isMovable = false
        launcherPanel.onDismiss = { [weak self] in self?.hideSidePanels() }
        panel = launcherPanel
        launcherPanel.present()
        showSidePanels()
    }

    /// Tasks pinned left, calendar pinned right — the ⌥Space heads-up display.
    private func showSidePanels() {
        hideSidePanels()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let tasks = FloatingPanel(content: TasksPanelView(), becomesKey: false)
        tasks.isMovable = false
        // Fixed by design (the views declare these exact frames) — measured
        // sizing returned 0×0 here and made the panels invisible.
        // Fixed by design — the views declare these exact frames.
        let tasksSize = NSSize(width: 260, height: 420)
        tasks.setFrame(
            NSRect(x: visible.minX + 20,
                   y: visible.midY - tasksSize.height / 2,
                   width: tasksSize.width, height: tasksSize.height),
            display: true
        )
        tasks.orderFrontRegardless()
        tasksPanel = tasks

        let calendar = FloatingPanel(content: CalendarPanelView(), becomesKey: false)
        calendar.isMovable = false
        let calendarSize = NSSize(width: 300, height: 420)
        calendar.setFrame(
            NSRect(x: visible.maxX - calendarSize.width - 20,
                   y: visible.midY - calendarSize.height / 2,
                   width: calendarSize.width, height: calendarSize.height),
            display: true
        )
        calendar.orderFrontRegardless()
        calendarPanel = calendar
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
            let top = panel.frame.maxY
            // Instant: the window is the anchor. All motion lives in the rows.
            panel.setFrame(
                NSRect(x: panel.frame.minX, y: top - size.height,
                       width: size.width, height: size.height),
                display: true
            )
        }
    }

    private func hideSidePanels() {
        tasksPanel?.orderOut(nil)
        tasksPanel = nil
        calendarPanel?.orderOut(nil)
        calendarPanel = nil
    }
}
