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
    private var alarm: Timer?
    var onFinish: () -> Void = { NSSound.beep() }

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
        deadline = now.addingTimeInterval(seconds)
        pausedSeconds = nil
        finished = false
        alarm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick(now: Date = Date()) {
        guard let deadline, now >= deadline else { return }
        alarm?.invalidate(); alarm = nil
        self.deadline = nil
        finished = true
        onFinish()
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
    }

    func save() {
        guard tool.canSave else { return }
        feedback = NotesStore().save(body: tool.markdown(checked: checked), source: "quick_tools") == nil
            ? "Couldn’t save. Your card is still here; try again." : "Saved to Notes"
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
                .onSubmit { model.save() }
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
                    } else { QuickToolCard(model: model) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text(model.tool.title).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
            content
            if model.tool.canSave {
                HStack(spacing: MM.Layout.spacing) {
                    Button("Save to Notes") { model.save() }.clickable()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.tool.markdown(checked: model.checked), forType: .string)
                        model.feedback = "Copied"
                    }.clickable()
                    Spacer()
                }.font(MM.Fonts.secondary)
            }
            if !model.feedback.isEmpty {
                Text(model.feedback).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    .accessibilityLabel(model.feedback)
            }
        }
        .padding(MM.Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
    }

    @ViewBuilder private var content: some View {
        switch model.tool {
        case .note(let text): Text(text).font(MM.Fonts.body).textSelection(.enabled)
        case .incomplete(_, let help): Text(help).font(MM.Fonts.body)
        case .calculation(let expression, let result):
            Text(expression).font(MM.Fonts.body).textSelection(.enabled)
            Text(QuickTool.number(result)).font(MM.Fonts.title).textSelection(.enabled)
        case .conversion(let input, let result, let unit):
            Text(input).font(MM.Fonts.body)
            Text("\(QuickTool.number(result)) \(unit)").font(MM.Fonts.title).textSelection(.enabled)
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
            Text("\(QuickTool.number(seconds / 60)) minutes").font(MM.Fonts.title)
            Button("Start timer") { model.start(seconds: seconds) }.clickable()
                .disabled(model.deadline != nil || model.pausedSeconds != nil)
            Text("The timer keeps running while My Man is open, even when this panel is closed.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
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
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            // This is user-supplied color data, not an interface color token.
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                .fill(Color(red: Double((value >> 16) & 255) / 255,
                            green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255))
                .frame(height: 72).accessibilityLabel("Color swatch \(hex)")
            Text(hex).font(MM.Fonts.title).textSelection(.enabled)
            Text("RGB \((value >> 16) & 255), \((value >> 8) & 255), \(value & 255)").font(MM.Fonts.secondary)
        }
    }
}

struct QuickTimerStatus: View {
    @ObservedObject var model: QuickToolsModel

    var body: some View {
        if model.deadline != nil || model.pausedSeconds != nil || model.finished {
            HStack(spacing: MM.Layout.spacing) {
                if let deadline = model.deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                        Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                            .font(MM.Fonts.title).monospacedDigit()
                    }
                    Button("Pause") { model.pause() }.clickable()
                } else if let seconds = model.pausedSeconds {
                    Text("Paused").font(MM.Fonts.body)
                    Button("Resume") { model.start(seconds: seconds) }.clickable()
                } else { Text("Timer finished").font(MM.Fonts.title) }
                Spacer()
                Button(model.finished ? "Dismiss" : "Cancel timer") { model.stop() }.clickable()
            }.font(MM.Fonts.secondary).padding(MM.Layout.padding)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        }
    }
}
