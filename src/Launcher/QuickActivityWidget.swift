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
    private var lastShake = Date.distantPast
    /// How long a finished timer keeps nudging for attention, and how often.
    static let shakeWindow: TimeInterval = 60
    static let shakeInterval: TimeInterval = 3

    init(timer: QuickToolsModel? = nil, reminders: ReminderStore? = nil) {
        self.timer = timer ?? QuickToolsController.shared.model
        self.reminders = reminders ?? .shared
    }

    static let pillSize = NSSize(width: 178, height: 44)
    static let pillSpacing: CGFloat = 8
    static let maxTimerPills = 4

    var count: Int { timer.timers.count + reminders.reminders.count }
    /// Finished first, then soonest to end; paused timers sink to the bottom.
    var sortedTimers: [QuickTimer] {
        let now = now
        func key(_ t: QuickTimer) -> (Int, TimeInterval) {
            (t.finished ? 0 : t.deadline != nil ? 1 : 2, t.finished ? -(t.finishedAt ?? .distantPast).timeIntervalSince1970 : t.remaining(at: now))
        }
        return timer.timers.sorted { key($0) < key($1) }
    }
    var stackedTimers: [QuickTimer] { Array(sortedTimers.prefix(Self.maxTimerPills)) }
    var hiddenTimerCount: Int { max(0, timer.timers.count - Self.maxTimerPills) }
    var pillCount: Int { stackedTimers.count + (reminders.reminders.isEmpty ? 0 : 1) }
    var size: NSSize {
        if expanded {
            let rows = 24 + CGFloat(timer.timers.count) * 76 + CGFloat(reminders.reminders.count) * 112
            return NSSize(width: 340, height: min(420, rows))
        }
        let pills = CGFloat(max(1, pillCount))
        return NSSize(width: Self.pillSize.width, height: pills * Self.pillSize.height + (pills - 1) * Self.pillSpacing)
    }
    var nextReminder: LocalReminder? { reminders.reminders.min { $0.date < $1.date } }
    var showsTimer: Bool {
        guard let first = sortedTimers.first else { return false }
        guard let reminder = nextReminder else { return true }
        if first.finished { return true }
        return (first.deadline ?? .distantFuture) <= reminder.date
    }
    var countdown: String {
        if showsTimer, let first = sortedTimers.first { return Self.pillText(first, now: now) }
        guard let reminder = nextReminder else { return "" }
        return reminder.date <= now ? "Reminder due" : Self.time(reminder.date.timeIntervalSince(now))
    }

    static func pillText(_ timer: QuickTimer, now: Date) -> String {
        if timer.finished { return "Time’s up" }
        if let paused = timer.pausedSeconds { return "Paused · " + time(paused) }
        return time(timer.remaining(at: now))
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
                self.shakeIfRinging()
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

    /// A finished timer shakes the stack like a rejected password field, every
    /// few seconds for its first minute. Reduce Motion keeps it still.
    private func shakeIfRinging() {
        guard let panel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              timer.timers.contains(where: { $0.finished && now.timeIntervalSince($0.finishedAt ?? .distantPast) < Self.shakeWindow }),
              now.timeIntervalSince(lastShake) >= Self.shakeInterval else { return }
        lastShake = now
        let origin = panel.frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for offset in [-10.0, 9, -7, 5, -3, 0] { path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y)) }
        let shake = CAKeyframeAnimation()
        shake.path = path
        shake.duration = 0.45
        panel.animations = ["frameOrigin": shake]
        panel.animator().setFrameOrigin(origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in panel?.animations = [:] }
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
                        ForEach(controller.sortedTimers) { timerRow($0) }
                        ForEach(reminders.reminders.sorted { $0.date < $1.date }) { reminder in reminderRow(reminder) }
                    }.padding(.vertical, MM.Layout.spacing)
                }
                .foregroundStyle(MM.Colors.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .card()
            } else {
                VStack(spacing: QuickActivityWidgetController.pillSpacing) {
                    let stacked = controller.stackedTimers
                    ForEach(stacked) { item in
                        QuickTimerPill(timer: item, now: controller.now,
                                       overflow: item.id == stacked.last?.id ? controller.hiddenTimerCount : 0,
                                       onExpand: { controller.setExpanded(true) },
                                       onDismiss: { timer.stop(item.id) })
                    }
                    if let reminder = controller.nextReminder { reminderPill(reminder) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onHover { controller.hover($0) }
    }

    private func reminderPill(_ reminder: LocalReminder) -> some View {
        let text = reminder.date <= controller.now ? "Reminder due" : QuickActivityWidgetController.time(reminder.date.timeIntervalSince(controller.now))
        return Button { controller.setExpanded(true) } label: {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: .reminder, color: MM.Colors.accent)
                Text(text).font(MM.Fonts.secondary).monospacedDigit()
                if reminders.reminders.count > 1 {
                    Text("+\(reminders.reminders.count - 1)").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clickable()
        }.buttonStyle(.plain)
            .foregroundStyle(MM.Colors.textPrimary)
            .frame(height: QuickActivityWidgetController.pillSize.height)
            .card()
            .accessibilityLabel("\(reminder.title), \(text). Expand timers and reminders")
    }

    private func timerRow(_ item: QuickTimer) -> some View {
        HStack(spacing: MM.Layout.spacing) {
            IconView(icon: .timer, color: MM.Colors.accent)
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(item.finished ? "Time’s up · \(item.label)" : item.pausedSeconds != nil ? "\(item.label) · Paused" : item.label)
                    .font(MM.Fonts.secondary)
                Text(QuickActivityWidgetController.time(item.remaining(at: controller.now)))
                    .font(MM.Fonts.title).monospacedDigit()
            }
            Spacer(minLength: 0)
            soundButton(enabled: item.soundEnabled) { timer.setSound(!item.soundEnabled, id: item.id) }
            if !item.finished {
                Button(item.deadline == nil ? "Resume" : "Pause") {
                    if item.deadline != nil { timer.pause(item.id) } else { timer.resume(item.id) }
                }.font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
            }
            Button { timer.stop(item.id) } label: { IconView(icon: .close).clickable() }
                .buttonStyle(.plain).help("Dismiss timer").accessibilityLabel("Dismiss \(item.label) timer")
        }.padding(.horizontal, MM.Layout.padding).frame(height: 76)
    }

    private func reminderRow(_ reminder: LocalReminder) -> some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            HStack(alignment: .top, spacing: MM.Layout.spacing) {
                Text(reminder.title).font(MM.Fonts.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).help(reminder.title)
                Button { reminders.dismiss(reminder.id) } label: {
                    IconView(icon: .close).clickable(minSize: 28)
                }.buttonStyle(.plain).help("Dismiss reminder").accessibilityLabel("Dismiss reminder: \(reminder.title)")
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                    Text(reminder.date <= controller.now ? "Due now" : QuickActivityWidgetController.time(reminder.date.timeIntervalSince(controller.now)))
                        .font(MM.Fonts.title).monospacedDigit()
                    Text(reminder.date.formatted(date: .abbreviated, time: .shortened))
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
                Spacer()
                soundButton(enabled: reminder.playsSound) {
                    Task { try? await reminders.setSoundEnabled(!reminder.playsSound, for: reminder.id) }
                }
            }
        }.padding(.horizontal, MM.Layout.padding).frame(height: 112)
    }

    private func soundButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon: enabled ? .bell : .bellOff, color: enabled ? MM.Colors.accent : MM.Colors.textTertiary).clickable(minSize: 28)
        }.buttonStyle(.plain)
            .accessibilityLabel(enabled ? "Turn sound off" : "Turn sound on")
            .help(enabled ? "Sound on · Click to mute" : "Sound off · Click to enable")
    }
}

/// One timer in the collapsed top-right stack. A finished timer pulses and its
/// icon wiggles until dismissed; the window itself also shakes (see controller).
private struct QuickTimerPill: View {
    let timer: QuickTimer
    let now: Date
    let overflow: Int
    let onExpand: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = QuickActivityWidgetController.pillText(timer, now: now)
        HStack(spacing: MM.Layout.spacing) {
            Button(action: onExpand) {
                HStack(spacing: MM.Layout.spacing) {
                    icon
                    Text(text).font(MM.Fonts.secondary).monospacedDigit()
                    if overflow > 0 {
                        Text("+\(overflow)").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clickable()
            }.buttonStyle(.plain)
                .accessibilityLabel("\(timer.label) timer, \(text). Expand timers and reminders")
            if timer.finished {
                Button(action: onDismiss) { IconView(icon: .close).clickable(minSize: 28) }
                    .buttonStyle(.plain).help("Dismiss timer").accessibilityLabel("Dismiss \(timer.label) timer")
                    .padding(.trailing, MM.Layout.spacing)
            }
        }
        .foregroundStyle(MM.Colors.textPrimary)
        .frame(height: QuickActivityWidgetController.pillSize.height)
        .background { if timer.finished { pulse } }
        .card(highlighted: timer.finished)
    }

    @ViewBuilder private var icon: some View {
        let base = IconView(icon: .timer, color: MM.Colors.accent)
        if timer.finished && !reduceMotion {
            base.phaseAnimator([-14.0, 14.0]) { view, angle in view.rotationEffect(.degrees(angle)) }
                animation: { _ in .easeInOut(duration: 0.09) }
        } else { base }
    }

    @ViewBuilder private var pulse: some View {
        if reduceMotion { MM.Colors.accent.opacity(0.18) }
        else {
            MM.Colors.accent.phaseAnimator([0.08, 0.28]) { color, opacity in color.opacity(opacity) }
                animation: { _ in .easeInOut(duration: 0.6) }
        }
    }
}

private extension View {
    func card(highlighted: Bool = false) -> some View {
        background(MM.Colors.background, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius)
                .strokeBorder(highlighted ? MM.Colors.accent : MM.Colors.border, lineWidth: highlighted ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radius))
    }
}
