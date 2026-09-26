import AppKit
import SwiftUI

struct QuickTimer: Identifiable, Equatable {
    let id: String
    let duration: TimeInterval
    var deadline: Date?
    var pausedSeconds: TimeInterval?
    var finished = false
    var finishedAt: Date?
    var soundEnabled = true
    var agentOwner: String?

    var state: String { finished ? "finished" : pausedSeconds != nil ? "paused" : "running" }
    func remaining(at now: Date) -> TimeInterval {
        finished ? 0 : max(0, deadline?.timeIntervalSince(now) ?? pausedSeconds ?? 0)
    }
    /// A short name so stacked timers are distinguishable, e.g. "10 min".
    var label: String {
        let total = Int(duration.rounded())
        if total % 3600 == 0 { return "\(total / 3600) hr" }
        if total >= 3600 { return "\(total / 3600) hr \(total / 60 % 60) min" }
        if total % 60 == 0 { return "\(total / 60) min" }
        return total > 60 ? "\(total / 60) min \(total % 60) sec" : "\(total) sec"
    }
}

@MainActor
final class QuickToolsModel: ObservableObject {
    @Published var tool: QuickTool = .note("")
    @Published var checked: Set<Int> = []
    @Published var feedback = ""
    /// Every running, paused, or finished timer, oldest first. The singular
    /// accessors below address the newest one for single-timer call sites.
    @Published private(set) var timers: [QuickTimer] = []
    @Published private(set) var startingActivity = false
    private var alarm: Timer?
    var onFinish: () -> Void = { QuickCompletionSound.startAlarm() }
    var onAlarmCleared: () -> Void = { QuickCompletionSound.stopAlarm() }
    var timerActive: Bool { !timers.isEmpty }
    var deadline: Date? { timers.last?.deadline }
    var pausedSeconds: TimeInterval? { timers.last?.pausedSeconds }
    var finished: Bool { timers.last?.finished ?? false }
    var timerID: String? { timers.last?.id }
    var timerAgentOwner: String? {
        get { timers.last?.agentOwner }
        set { if let id = timerID { mutate(id) { $0.agentOwner = newValue } } }
    }
    var soundEnabled: Bool {
        get { timers.last?.soundEnabled ?? true }
        set { if let id = timerID { setSound(newValue, id: id) } }
    }
    var ringing: Bool { timers.contains { $0.finished && $0.soundEnabled } }

    func timer(_ id: String) -> QuickTimer? { timers.first { $0.id == id } }

    func update(_ input: String) {
        let next = QuickToolParser.parse(input)
        guard tool != next else { return }
        if case .checklist(let oldItems) = tool, case .checklist(let newItems) = next {
            checked = Set(newItems.indices.filter { index in
                oldItems.indices.contains(index) && oldItems[index] == newItems[index] && checked.contains(index)
            })
        } else { checked = [] }
        tool = next
        feedback = ""
    }

    /// Resumes the newest timer when it is paused; otherwise adds a new one.
    func start(seconds: TimeInterval, now: Date = Date()) {
        if let id = timerID, pausedSeconds != nil { resume(id, now: now) }
        else { addTimer(seconds: seconds, now: now) }
    }

    @discardableResult
    func addTimer(seconds: TimeInterval, soundEnabled: Bool = true, owner: String? = nil, now: Date = Date()) -> String {
        let timer = QuickTimer(id: UUID().uuidString, duration: seconds, deadline: now.addingTimeInterval(seconds),
                               soundEnabled: soundEnabled, agentOwner: owner)
        timers.append(timer)
        scheduleTicks()
        return timer.id
    }

    func resume(_ id: String, now: Date = Date()) {
        guard let seconds = timer(id)?.pausedSeconds else { return }
        mutate(id) { $0.deadline = now.addingTimeInterval(seconds); $0.pausedSeconds = nil }
        scheduleTicks()
    }

    func pause(_ id: String, now: Date = Date()) {
        guard let deadline = timer(id)?.deadline else { return }
        mutate(id) { $0.pausedSeconds = max(0, deadline.timeIntervalSince(now)); $0.deadline = nil }
        scheduleTicks()
    }

    func stop(_ id: String) {
        timers.removeAll { $0.id == id }
        scheduleTicks()
        if !ringing { onAlarmCleared() }
    }

    func setSound(_ enabled: Bool, id: String) {
        mutate(id) { $0.soundEnabled = enabled }
        if !ringing { onAlarmCleared() }
    }

    private func mutate(_ id: String, _ change: (inout QuickTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        change(&timers[index])
    }

    private func scheduleTicks() {
        let running = timers.contains { $0.deadline != nil }
        if !running { alarm?.invalidate(); alarm = nil; return }
        guard alarm == nil else { return }
        alarm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        alarm.map { RunLoop.main.add($0, forMode: .common) }
    }

    /// Parsing stays side-effect free. Return, a labeled button, or a completed
    /// spoken request explicitly commits only timers and complete reminders.
    func startActivity(_ requested: QuickTool? = nil, reminders: ReminderStore? = nil) async -> Bool {
        guard !startingActivity else { return false }
        switch requested ?? tool {
        case .timer(let seconds):
            addTimer(seconds: seconds)
            return true
        case .reminder(let draft):
            guard draft.hasExplicitTime else { return false }
            startingActivity = true
            defer { startingActivity = false }
            do {
                _ = try await (reminders ?? .shared).create(draft, waitForNotification: false)
                return true
            } catch { feedback = error.localizedDescription; return false }
        default: return false
        }
    }

    func tick(now: Date = Date()) {
        var alert = false
        for index in timers.indices {
            guard let deadline = timers[index].deadline, now >= deadline else { continue }
            timers[index].deadline = nil
            timers[index].finished = true
            timers[index].finishedAt = now
            alert = alert || timers[index].soundEnabled
        }
        scheduleTicks()
        if alert { onFinish() }
    }

    func pause(now: Date = Date()) { if let id = timerID { pause(id, now: now) } }

    /// Clears every timer.
    func stop() {
        timers.removeAll()
        scheduleTicks()
        onAlarmCleared()
    }

    func save() {
        guard tool.canSave else { return }
        feedback = NotesStore().save(body: tool.markdown(checked: checked), source: "quick_tools") == nil
            ? "Couldn’t save. Your card is still here; try again." : "Saved to Notes"
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.markdown(checked: checked), forType: .string)
        feedback = "Copied"
    }
}

@MainActor
final class QuickToolsController {
    static let shared = QuickToolsController()
    let model = QuickToolsModel()
    private var panel: FloatingPanel?
    private var draft = ""

    func show() {
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        let view = QuickToolsView(model: model, initialText: draft, onChange: { [weak self] in self?.draft = $0 },
                                  onDismiss: { [weak self] in self?.panel?.dismiss() })
        let panel = FloatingPanel(content: view, fixedSize: true)
        panel.dismissesOnResign = false
        panel.setContentSize(NSSize(width: MM.Layout.panelWidth, height: 500))
        self.panel = panel
        panel.present()
    }
}

struct QuickToolsView: View {
    @ObservedObject var model: QuickToolsModel
    var initialText = ""
    var onChange: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Text("Quick Tools").font(MM.Fonts.title)
                Spacer()
                Button(action: onDismiss) { IconView(icon: .close) }.buttonStyle(.plain)
                    .clickable().accessibilityLabel("Close Quick Tools")
            }
            TextField("Type a calculation, checklist, timer…", text: $text)
                .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                .padding(MM.Layout.padding)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .onSubmit {
                    switch model.tool {
                    case .timer, .reminder:
                        Task { @MainActor in if await model.startActivity() { onDismiss() } }
                    default: model.save()
                    }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                    if text.isEmpty {
                        Text("Type it. Use it.").font(MM.Fonts.title)
                        Text("A useful card appears as you type. Everything stays on your Mac.")
                            .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                        ForEach(QuickToolParser.examples, id: \.self) { example in
                            Button(example) { text = example }.buttonStyle(.plain).clickable()
                                .font(MM.Fonts.body)
                        }
                    } else { QuickToolCard(model: model, onActivityStarted: onDismiss) }
                    QuickTimerStatus(model: model)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(MM.Layout.paddingLarge)
        .foregroundStyle(MM.Colors.textPrimary)
        .background(MM.Colors.background, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border))
        .onAppear { text = initialText; model.update(text); focused = true }
        .onChange(of: text) { _, new in model.update(new); onChange(new) }
    }
}

struct QuickToolCard: View {
    @ObservedObject var model: QuickToolsModel
    var onTyping: () -> Void = {}
    var onActivityStarted: () -> Void = {}
    var reminders: ReminderStore? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            if model.tool.isTimer { content }
            else {
                HStack(alignment: .top, spacing: MM.Layout.spacing) {
                    VStack(alignment: .leading, spacing: MM.Layout.spacing) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.tool.canSave {
                        Button { model.copy() } label: { IconView(icon: .copy).clickable() }
                            .buttonStyle(.plain).help("Copy").accessibilityLabel("Copy")
                    }
                }
            }
            if !model.feedback.isEmpty {
                Text(model.feedback).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    .accessibilityLabel(model.feedback)
            }
        }
        .padding(MM.Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if model.tool.canSave && !model.tool.isTimer {
                Button("Copy") { model.copy() }
                Button("Save to Notes") { model.save() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tool {
        case .note(let text): Text(text).font(MM.Fonts.body).textSelection(.enabled)
        case .incomplete(_, let help): Text(help).font(MM.Fonts.body)
        case .calculator: QuickCalculatorInput(onTyping: onTyping)
        case .reminder(let draft): QuickReminderInput(model: model, draft: draft, onTyping: onTyping, onStarted: onActivityStarted, reminders: reminders)
        case .calculation(_, let result):
            Text(QuickTool.number(result)).font(MM.Fonts.result).textSelection(.enabled)
        case .conversion(_, let result, let unit):
            Text("\(QuickTool.number(result)) \(unit)").font(MM.Fonts.result).textSelection(.enabled)
        case .timeZone(let conversion):
            let zones = conversion.displayZones
            HStack(spacing: MM.Layout.paddingLarge) {
                zoneTime(conversion, zone: zones[0].zone, name: zones[0].name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("→").font(MM.Fonts.title).foregroundStyle(MM.Colors.textTertiary)
                zoneTime(conversion, zone: zones[1].zone, name: zones[1].name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .checklist(let items):
            ForEach(items.indices, id: \.self) { index in
                Button {
                    if !model.checked.insert(index).inserted { model.checked.remove(index) }
                    model.feedback = ""
                } label: {
                    HStack(alignment: .top, spacing: MM.Layout.spacing) {
                        IconView(icon: model.checked.contains(index) ? .checklistChecked : .checklistUnchecked)
                        Text(items[index]).font(MM.Fonts.body).strikethrough(model.checked.contains(index))
                        Spacer()
                    }.clickable()
                }.buttonStyle(.plain).accessibilityLabel("\(items[index]), \(model.checked.contains(index) ? "checked" : "unchecked")")
            }
        case .timer(let seconds):
            QuickTimerRow(model: model, seconds: seconds, onStarted: onActivityStarted)
        case .split(let cents, let people, let currency):
            Text("\(currency)\(QuickTool.money(cents)) total").font(MM.Fonts.body)
            Stepper("\(people) people", value: Binding(get: { people }, set: {
                model.tool = .split(cents: cents, people: $0, currency: currency); model.feedback = ""
            }), in: 1...1_000).font(MM.Fonts.body).clickable()
            Text(QuickTool.splitSummary(cents: cents, people: people, currency: currency))
                .font(MM.Fonts.title).textSelection(.enabled)
            if cents % people != 0 {
                Text("The extra cents are shared so the amounts add up exactly.").font(MM.Fonts.metadata)
            }
        case .color(let hex):
            QuickColorPaletteView(hex: hex) { model.feedback = "Copied \($0)" }
        }
    }

    private func zoneTime(_ conversion: QuickTimeZone, zone: TimeZone, name: String) -> some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            Text(name).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
            Text(conversion.time(in: zone)).font(MM.Fonts.title).monospacedDigit()
            Text(conversion.day(in: zone)).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
        }.textSelection(.enabled)
    }
}

private struct QuickCalculatorInput: View {
    var onTyping: () -> Void
    @State private var expression = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    private var answer: String? {
        if case .calculation(_, let result) = QuickToolParser.parse(expression) { return QuickTool.number(result) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            TextField("Enter a calculation…", text: Binding(get: { expression }, set: {
                guard expression != $0 else { return }
                onTyping(); expression = $0; copied = false
            }))
                .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                .accessibilityLabel("Calculation")
            if let answer {
                HStack {
                    Text(answer).font(MM.Fonts.result).textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                        copied = true
                    } label: { IconView(icon: .copy).clickable() }
                        .buttonStyle(.plain).help(copied ? "Copied" : "Copy answer").accessibilityLabel("Copy answer")
                }
            } else if !expression.isEmpty {
                Text("Enter a valid expression").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
        }.onAppear { focused = true }
    }
}

struct QuickReminderInput: View {
    @ObservedObject var model: QuickToolsModel
    let draft: ReminderDraft
    var onTyping: () -> Void
    var onStarted: () -> Void
    var reminders: ReminderStore?
    @State private var title = ""
    @State private var date = Date()
    @State private var feedback = ""
    @State private var saving = false
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            TextField("What should I remind you about?", text: Binding(get: { title }, set: {
                guard title != $0 else { return }
                onTyping(); title = $0; feedback = ""; saved = false
            })).textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                .onSubmit { saveReminder() }
            ReminderSchedulePicker(date: Binding(get: { date }, set: {
                onTyping(); date = $0; feedback = ""; saved = false
            }))
            HStack(spacing: MM.Layout.spacing) {
                Text(date <= Date() ? "Choose a future time" : date.formatted(date: .abbreviated, time: .shortened))
                    .font(MM.Fonts.metadata).foregroundStyle(date <= Date() ? MM.Colors.danger : MM.Colors.textSecondary)
                Spacer()
                Button { saveReminder() } label: {
                    Text(saving ? "Setting…" : saved ? "Set" : "Set reminder").font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.onAccent)
                        .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                        .background(MM.Colors.accent, in: Capsule()).clickable()
                }.buttonStyle(.plain).disabled(saving || saved || model.startingActivity || date <= Date() || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !feedback.isEmpty { Text(feedback).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary) }
        }
        .onAppear { title = draft.title; date = draft.date; focused = title.isEmpty }
        .onChange(of: draft) { _, value in title = value.title; date = value.date; feedback = ""; saved = false }
    }

    private func saveReminder() {
        guard !saving, !saved, !model.startingActivity, date > Date(),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task { @MainActor in
            saved = await model.startActivity(.reminder(.init(title: title, date: date)), reminders: reminders)
            feedback = saved ? "Reminder set" : model.feedback
            saving = false
            if saved { onStarted() }
        }
    }
}

/// Existing timers, newest first. The top-right widget shows the full stack.
struct QuickTimerStatus: View {
    @ObservedObject var model: QuickToolsModel
    static let visibleLimit = 3

    var body: some View {
        if model.timerActive {
            let newest = Array(model.timers.reversed())
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                ForEach(newest.prefix(Self.visibleLimit)) { timer in QuickActiveTimerRow(model: model, timer: timer) }
                if newest.count > Self.visibleLimit {
                    Text("\(newest.count - Self.visibleLimit) more in the timer stack")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
            }.padding(MM.Layout.padding)
        }
    }
}

/// The typed-timer preview. Starting always adds a timer beside existing ones.
private struct QuickTimerRow: View {
    @ObservedObject var model: QuickToolsModel
    let seconds: TimeInterval
    var onStarted: () -> Void = {}

    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(model.timerActive ? "New timer" : "Timer")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                QuickTimerClock(seconds: seconds)
            }
            Spacer()
            Button {
                model.addTimer(seconds: seconds)
                onStarted()
            } label: {
                Text("Start")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.onAccent)
                    .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                    .background(MM.Colors.accent, in: Capsule()).clickable()
            }.buttonStyle(.plain)
        }
    }
}

private struct QuickActiveTimerRow: View {
    @ObservedObject var model: QuickToolsModel
    let timer: QuickTimer

    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(timer.finished ? "\(timer.label) · Time’s up" : timer.pausedSeconds != nil ? "\(timer.label) · Paused" : timer.label)
                    .font(MM.Fonts.metadata).foregroundStyle(timer.finished ? MM.Colors.accent : MM.Colors.textTertiary)
                if let deadline = timer.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        QuickTimerClock(seconds: deadline.timeIntervalSince(context.date))
                    }
                } else { QuickTimerClock(seconds: timer.remaining(at: Date())) }
            }
            Spacer()
            if !timer.finished {
                Button {
                    if timer.deadline != nil { model.pause(timer.id) } else { model.resume(timer.id) }
                } label: {
                    Text(timer.deadline != nil ? "Pause" : "Resume")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.onAccent)
                        .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                        .background(MM.Colors.accent, in: Capsule()).clickable()
                }.buttonStyle(.plain)
            }
            Button { model.stop(timer.id) } label: { IconView(icon: .close).clickable() }
                .buttonStyle(.plain).help(timer.finished ? "Dismiss timer" : "Cancel timer")
                .accessibilityLabel(timer.finished ? "Dismiss \(timer.label) timer" : "Cancel \(timer.label) timer")
        }
    }
}

private struct QuickTimerClock: View {
    let seconds: TimeInterval

    var body: some View {
        let total = max(0, Int(ceil(seconds)))
        Text(total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60))
            .font(MM.Fonts.title).monospacedDigit()
    }
}
