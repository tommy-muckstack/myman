import AppKit
import Combine
import SwiftUI

/// The window owns its frame; hover updates are deferred outside SwiftUI layout.
@MainActor final class QuickActivityWidgetController: ObservableObject {
    static let shared = QuickActivityWidgetController()
    @Published private(set) var expanded = false
    @Published private(set) var now = Date()
    let timer: QuickToolsModel
    let reminders: ReminderStore
    private var panel: FloatingPanel?
    private var screen: NSScreen?
    private var ticker: Timer?
    private var observers: Set<AnyCancellable> = []
    private var refreshQueued = false
    private var collapse: Task<Void, Never>?

    init(timer: QuickToolsModel? = nil, reminders: ReminderStore? = nil) {
        self.timer = timer ?? QuickToolsController.shared.model
        self.reminders = reminders ?? .shared
    }

    var count: Int { (timer.timerActive ? 1 : 0) + reminders.reminders.count }
    var size: NSSize {
        expanded ? NSSize(width: 340, height: min(340, 24 + CGFloat(count) * 76)) : NSSize(width: 178, height: 44)
    }
    var nextReminder: LocalReminder? { reminders.reminders.min { $0.date < $1.date } }
    var showsTimer: Bool {
        guard timer.timerActive else { return false }
        guard let reminder = nextReminder else { return true }
        if timer.finished { return true }
        return (timer.deadline ?? .distantFuture) <= reminder.date
    }
    var countdown: String {
        if showsTimer {
            if timer.finished { return "Time’s up" }
            if timer.pausedSeconds != nil { return "Paused · " + Self.time(timer.pausedSeconds ?? 0) }
            return Self.time(timer.deadline?.timeIntervalSince(now) ?? 0)
        }
        guard let reminder = nextReminder else { return "" }
        return reminder.date <= now ? "Reminder due" : Self.time(reminder.date.timeIntervalSince(now))
    }

    func start() {
        guard ticker == nil else { return }
        ReminderStore.configureNotifications()
        timer.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &observers)
        reminders.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &observers)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.reminders.tick(now: self.now)
                self.queueRefresh()
            }
        }
        queueRefresh()
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        observers.removeAll()
        collapse?.cancel(); collapse = nil
        panel?.orderOut(nil); panel = nil; screen = nil
        expanded = false
    }

    func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside { setExpanded(true) }
        else {
            collapse = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if self.panel?.frame.contains(NSEvent.mouseLocation) != true { self.setExpanded(false) }
            }
        }
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        queueRefresh()
    }

    private func queueRefresh() {
        guard ticker != nil, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        guard ticker != nil else { return }
        now = Date()
        guard count > 0 else {
            panel?.orderOut(nil); panel = nil; screen = nil
            expanded = false
            return
        }
        let isNew = panel == nil
        if isNew {
            let new = FloatingPanel(content: QuickActivityWidget(controller: self), becomesKey: false, fixedSize: true)
            new.dismissesOnResign = false
            new.isMovableByWindowBackground = false
            new.identifier = NSUserInterfaceItemIdentifier("myman.quick-activity")
            panel = new
            screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        guard let panel, let screen = screen ?? NSScreen.main else { return }
        let meeting = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "myman.meeting-indicator" }?.frame
        let frame = Self.frame(size: size, visible: screen.visibleFrame, avoiding: meeting)
        guard frame != panel.frame else { return }
        if isNew || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
        if isNew { panel.orderFrontRegardless() }
    }

    static func frame(size: NSSize, visible: NSRect, avoiding occupied: NSRect?) -> NSRect {
        var frame = NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                           width: size.width, height: size.height)
        if let occupied, frame.intersects(occupied.insetBy(dx: -12, dy: -12)) {
            frame.origin.y = occupied.minY - size.height - 12
            if frame.minY < visible.minY + 12 {
                frame.origin.y = visible.maxY - size.height - 24
                frame.origin.x = max(visible.minX + 12, occupied.minX - size.width - 12)
            }
        }
        return frame
    }

    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        if total >= 86_400 { return "\(total / 86_400)d \(total / 3_600 % 24)h" }
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct QuickActivityWidget: View {
    @ObservedObject var controller: QuickActivityWidgetController
    @ObservedObject private var timer: QuickToolsModel
    @ObservedObject private var reminders: ReminderStore

    init(controller: QuickActivityWidgetController) {
        self.controller = controller
        timer = controller.timer
        reminders = controller.reminders
    }

    var body: some View {
        Group {
            if controller.expanded {
                ScrollView {
                    VStack(spacing: 0) {
                        if timer.timerActive { timerRow }
                        ForEach(reminders.reminders.sorted { $0.date < $1.date }) { reminder in reminderRow(reminder) }
                    }.padding(.vertical, MM.Layout.spacing)
                }
            } else {
                Button { controller.setExpanded(true) } label: {
                    HStack(spacing: MM.Layout.spacing) {
                        IconView(icon: controller.showsTimer ? .timer : .reminder, color: MM.Colors.accent)
                        Text(controller.countdown).font(MM.Fonts.secondary).monospacedDigit()
                        if controller.count > 1 {
                            Text("+\(controller.count - 1)").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clickable()
                }.buttonStyle(.plain).accessibilityLabel("\(controller.countdown). Expand timers and reminders")
            }
        }
        .foregroundStyle(MM.Colors.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MM.Colors.background, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border))
        .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radius))
        .onHover { controller.hover($0) }
    }

    private var timerRow: some View {
        HStack(spacing: MM.Layout.spacing) {
            IconView(icon: .timer, color: MM.Colors.accent)
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(timer.finished ? "Time’s up" : timer.pausedSeconds != nil ? "Timer paused" : "Timer").font(MM.Fonts.secondary)
                Text(QuickActivityWidgetController.time(timer.deadline?.timeIntervalSince(controller.now) ?? timer.pausedSeconds ?? 0))
                    .font(MM.Fonts.title).monospacedDigit()
            }
            Spacer(minLength: 0)
            soundButton(enabled: timer.soundEnabled) { timer.soundEnabled.toggle() }
            if !timer.finished {
                Button(timer.deadline == nil ? "Resume" : "Pause") {
                    if timer.deadline != nil { timer.pause() }
                    else { timer.start(seconds: timer.pausedSeconds ?? 0) }
                }.font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
            }
            Button { timer.stop() } label: { IconView(icon: .close).clickable() }
                .buttonStyle(.plain).help("Dismiss timer").accessibilityLabel("Dismiss timer")
        }.padding(.horizontal, MM.Layout.padding).frame(height: 76)
    }

    private func reminderRow(_ reminder: LocalReminder) -> some View {
        HStack(spacing: MM.Layout.spacing) {
            IconView(icon: .reminder, color: MM.Colors.accent)
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(reminder.title).font(MM.Fonts.secondary).lineLimit(2).help(reminder.title)
                Text(reminder.date <= controller.now ? "Due now" : QuickActivityWidgetController.time(reminder.date.timeIntervalSince(controller.now)))
                    .font(MM.Fonts.title).monospacedDigit()
            }
            Spacer(minLength: 0)
            soundButton(enabled: reminder.playsSound) {
                Task { try? await reminders.setSoundEnabled(!reminder.playsSound, for: reminder.id) }
            }
            Button { reminders.dismiss(reminder.id) } label: { IconView(icon: .close).clickable() }
                .buttonStyle(.plain).help("Dismiss reminder").accessibilityLabel("Dismiss reminder: \(reminder.title)")
        }.padding(.horizontal, MM.Layout.padding).frame(height: 76)
    }

    private func soundButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon: enabled ? .bell : .bellOff, color: enabled ? MM.Colors.accent : MM.Colors.textTertiary).clickable()
        }.buttonStyle(.plain)
            .accessibilityLabel(enabled ? "Turn sound off" : "Turn sound on")
            .help(enabled ? "Sound on · Click to mute" : "Sound off · Click to enable")
    }
}
