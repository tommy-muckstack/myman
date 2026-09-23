import AppKit
import SwiftUI

@MainActor
final class QuickToolsModel: ObservableObject {
    @Published var tool: QuickTool = .note("")
    @Published var checked: Set<Int> = []
    @Published var feedback = ""
    @Published private(set) var deadline: Date?
    @Published private(set) var pausedSeconds: TimeInterval?
    @Published private(set) var finished = false
    @Published var soundEnabled = true
    @Published private(set) var startingActivity = false
    private var alarm: Timer?
    private(set) var timerID: String?
    var timerAgentOwner: String?
    var onFinish: () -> Void = { QuickCompletionSound.play() }
    var timerActive: Bool { deadline != nil || pausedSeconds != nil || finished }

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

    func start(seconds: TimeInterval, now: Date = Date()) {
        alarm?.invalidate()
        if pausedSeconds == nil { timerID = UUID().uuidString; timerAgentOwner = nil; soundEnabled = true }
        deadline = now.addingTimeInterval(seconds)
        pausedSeconds = nil
        finished = false
        alarm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Parsing stays side-effect free. Return, a labeled button, or a completed
    /// spoken request explicitly commits only timers and complete reminders.
    func startActivity(_ requested: QuickTool? = nil, reminders: ReminderStore? = nil) async -> Bool {
        guard !startingActivity else { return false }
        switch requested ?? tool {
        case .timer(let seconds):
            guard !timerActive else { feedback = "A timer is already running. Use its widget to pause or cancel it."; return false }
            soundEnabled = true
            start(seconds: seconds)
            return true
        case .reminder(let draft):
            guard draft.hasExplicitTime else { return false }
            startingActivity = true
            defer { startingActivity = false }
            do {
                _ = try await (reminders ?? .shared).create(draft)
                return true
            } catch { feedback = error.localizedDescription; return false }
        default: return false
        }
    }

    func tick(now: Date = Date()) {
        guard let deadline, now >= deadline else { return }
        alarm?.invalidate(); alarm = nil
        self.deadline = nil
        finished = true
        if soundEnabled { onFinish() }
    }

    func pause(now: Date = Date()) {
        guard let deadline else { return }
        pausedSeconds = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
        alarm?.invalidate(); alarm = nil
    }

    func stop() {
        alarm?.invalidate(); alarm = nil
        deadline = nil; pausedSeconds = nil; finished = false
        timerID = nil; timerAgentOwner = nil
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
                    if !model.tool.isTimer { QuickTimerStatus(model: model) }
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
            HStack(spacing: MM.Layout.paddingLarge) {
                zoneTime(conversion, zone: conversion.source, name: conversion.sourceName)
                Text("→").font(MM.Fonts.title).foregroundStyle(MM.Colors.textTertiary)
                zoneTime(conversion, zone: conversion.destination, name: conversion.destinationName)
                Spacer(minLength: 0)
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

private struct QuickReminderInput: View {
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
            HStack(spacing: MM.Layout.spacing) {
                DatePicker("When", selection: Binding(get: { date }, set: { onTyping(); date = $0; feedback = ""; saved = false }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().font(MM.Fonts.secondary).datePickerStyle(.field)
                Spacer()
                Button {
                    saving = true
                    Task { @MainActor in
                        saved = await model.startActivity(.reminder(.init(title: title, date: date)), reminders: reminders)
                        feedback = saved ? "Reminder set" : model.feedback
                        saving = false
                        if saved { onStarted() }
                    }
                } label: {
                    Text(saving ? "Setting…" : saved ? "Set" : "Set reminder").font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.onAccent)
                        .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                        .background(MM.Colors.accent, in: Capsule()).clickable()
                }.buttonStyle(.plain).disabled(saving || saved || model.startingActivity || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !feedback.isEmpty { Text(feedback).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary) }
        }
        .onAppear { title = draft.title; date = draft.date; focused = title.isEmpty }
        .onChange(of: draft) { _, value in title = value.title; date = value.date; feedback = ""; saved = false }
    }
}

struct QuickTimerStatus: View {
    @ObservedObject var model: QuickToolsModel

    var body: some View {
        if model.timerActive {
            QuickTimerRow(model: model, seconds: 0).padding(MM.Layout.padding)
        }
    }
}

private struct QuickTimerRow: View {
    @ObservedObject var model: QuickToolsModel
    let seconds: TimeInterval
    var onStarted: () -> Void = {}

    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(model.finished ? "Timer finished" : model.pausedSeconds != nil ? "Paused" : "Timer")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                if let deadline = model.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        time(deadline.timeIntervalSince(context.date))
                    }
                } else { time(model.finished ? 0 : model.pausedSeconds ?? seconds) }
            }
            Spacer()
            if !model.finished {
                Button {
                    if model.deadline != nil { model.pause() }
                    else {
                        if !model.timerActive { model.soundEnabled = true }
                        model.start(seconds: model.pausedSeconds ?? seconds)
                        onStarted()
                    }
                } label: {
                    Text(model.deadline != nil ? "Pause" : model.pausedSeconds != nil ? "Resume" : "Start")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.onAccent)
                        .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                        .background(MM.Colors.accent, in: Capsule()).clickable()
                }.buttonStyle(.plain)
            }
            if model.timerActive {
                Button { model.stop() } label: { IconView(icon: .close).clickable() }
                    .buttonStyle(.plain).help(model.finished ? "Dismiss timer" : "Cancel timer")
                    .accessibilityLabel(model.finished ? "Dismiss timer" : "Cancel timer")
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> some View {
        let total = max(0, Int(ceil(seconds)))
        return Text(total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60))
            .font(MM.Fonts.title).monospacedDigit()
    }
}
