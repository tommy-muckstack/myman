import AppKit
import SwiftUI

struct AdaptiveLauncherView: View {
    let actions: [LauncherAction]
    var initialQuery = ""
    var libraryModel: CaptureLibraryModel? = nil
    @ObservedObject var voice = AdaptiveLauncherVoice()
    var onSaveQueryAsNote: (String) -> Void
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void
    @State private var query = ""
    @State private var routing = AdaptiveLauncherRouting()
    @StateObject private var filters = CaptureLibraryFilters()
    @State private var libraryMode: CaptureLibraryMode = .search
    @ObservedObject private var tools = QuickToolsController.shared.model
    @FocusState private var focused: Bool

    private var effectiveIntent: AdaptiveLauncherIntent {
        if let selection = routing.selection { return selection }
        if libraryMode != .search || filters.isBrowsing || filters.active { return .search }
        return routing.suggestion
    }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: .agent, color: MM.Colors.textTertiary)
                TextField("Find something or make something…", text: $query)
                    .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { moveResult("down") }
                    .onKeyPress(.upArrow) { moveResult("up") }
                if effectiveIntent == .search { CaptureFilterMenu(mode: $libraryMode, filters: filters) }
                Button { voice.toggle() } label: {
                    IconView(icon: voice.enabled ? .mic : .micOff,
                             color: voice.enabled ? MM.Colors.accent : MM.Colors.textTertiary)
                }.buttonStyle(.plain).clickable()
                    .accessibilityLabel(voice.enabled ? "Stop listening" : "Start listening")
                    .help(voice.enabled ? "Stop listening" : "Start listening")
                Button {
                    onDismiss(); SettingsController.shared.show()
                } label: { IconView(icon: .settings) }
                    .buttonStyle(.plain).clickable().accessibilityLabel("Settings")
            }.padding(MM.Layout.padding)

            if !trimmed.isEmpty || effectiveIntent == .search {
                Divider().overlay(MM.Colors.border)
                HStack(spacing: MM.Layout.spacing) {
                    modeButton("Search existing", intent: .search)
                    modeButton("Create new", intent: .create)
                    Spacer()
                    Button("Clear") { query = "" }.buttonStyle(.plain).clickable()
                }.font(MM.Fonts.secondary).padding(MM.Layout.padding)
                routedContent
            } else {
                HStack {
                    Text("Type / for actions and tools").font(MM.Fonts.metadata)
                    Spacer()
                    Button("Browse library") { routing.selection = .search; query = "find " }
                        .font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
                }.foregroundStyle(MM.Colors.textTertiary)
                    .padding(.horizontal, MM.Layout.padding).padding(.bottom, MM.Layout.spacing)
            }
            QuickTimerStatus(model: tools)
            HStack(spacing: MM.Layout.spacing) {
                Text(voice.status).font(MM.Fonts.metadata)
                if voice.phase == .listening {
                    ProgressView(value: Double(voice.level)).frame(width: 40).tint(MM.Colors.accent)
                        .accessibilityLabel("Microphone level")
                }
                if voice.phase == .denied {
                    Button("Microphone settings") { Permission.microphone.request() }
                        .font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
                }
                Spacer()
            }.foregroundStyle(MM.Colors.textSecondary)
                .padding(.horizontal, MM.Layout.padding).padding(.bottom, MM.Layout.spacing)
        }
        .foregroundStyle(MM.Colors.textPrimary)
        .frame(width: MM.Layout.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(MM.Colors.background, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border))
        .background(GeometryReader { geometry in
            Color.clear.onAppear { onSizeChange(geometry.size) }
                .onChange(of: geometry.size) { _, size in onSizeChange(size) }
        })
        .onAppear { query = initialQuery; focused = true }
        .onDisappear { voice.stop() }
        .onChange(of: voice.utterance) { _, utterance in
            if let utterance { query = AdaptiveLauncherVoice.appending(utterance.text, to: query) }
        }
        .onChange(of: query) { _, value in
            routing.update(value)
            if trimmed.isEmpty || trimmed == "/" { filters.reset(); libraryMode = .search }
            tools.update(AdaptiveLauncherIntent.creationText(value))
        }
        .task(id: query) {
            let input = query
            guard routing.selection == nil, AdaptiveLauncherIntent.resolve(input) == .choose, !input.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard routing.selection == nil else { return }
            let suggestion = await AdaptiveLauncherIntent.suggest(input)
            guard !Task.isCancelled, query == input, routing.selection == nil else { return }
            routing.suggestion = suggestion
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var routedContent: some View {
        switch effectiveIntent {
        case .search:
            CaptureLibraryView(query: Binding(get: { AdaptiveLauncherIntent.searchText(query) }, set: { query = $0 }),
                               mode: $libraryMode, controls: filters, onDismiss: onDismiss, onSaveQueryAsNote: onSaveQueryAsNote, model: libraryModel)
        case .create:
            ScrollView { QuickToolCard(model: tools) }.frame(height: 280)
                .padding(.horizontal, MM.Layout.padding).padding(.bottom, MM.Layout.padding)
        case .action(let id):
            if let action = actions.first(where: { $0.id == id }) {
                actionButton(action).padding(MM.Layout.padding)
            } else {
                Text("This action isn’t available on this Mac.").font(MM.Fonts.body).padding(MM.Layout.padding)
            }
        case .tasks: TasksPanelView().padding(MM.Layout.padding)
        case .calendar: CalendarPanelView().padding(MM.Layout.padding)
        case .commands:
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                ForEach(actions) { action in actionButton(action) }
                Button("My tasks") { query = "my tasks" }.buttonStyle(.plain).clickable()
                Button("My calendar") { query = "my calendar" }.buttonStyle(.plain).clickable()
                ForEach(QuickToolParser.examples, id: \.self) { example in
                    Button(example) { query = example }.buttonStyle(.plain).clickable()
                }
            }.font(MM.Fonts.body).padding(MM.Layout.padding)
        case .choose:
            Text("Search for something saved, or turn this into a new note or tool? Choose above.")
                .font(MM.Fonts.body).foregroundStyle(MM.Colors.textSecondary).padding(MM.Layout.padding)
        }
    }

    private func modeButton(_ title: String, intent: AdaptiveLauncherIntent) -> some View {
        Button {
            routing.selection = intent
            if intent == .create { filters.reset(); libraryMode = .search }
        } label: {
            Text(title).foregroundStyle(effectiveIntent == intent ? MM.Colors.textPrimary : MM.Colors.textSecondary)
                .padding(.horizontal, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing / 2)
                .background(effectiveIntent == intent ? MM.Colors.surface : .clear,
                            in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }.buttonStyle(.plain)
    }

    private func actionButton(_ action: LauncherAction) -> some View {
        Button {
            onDismiss(); action.run()
        } label: {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: action.icon)
                Text(action.title).font(MM.Fonts.body)
                if action.recording { RecordingDot() }
                Spacer()
            }.clickable()
        }.buttonStyle(.plain).disabled(!action.enabled)
    }

    private func submit() {
        switch effectiveIntent {
        case .search:
            NotificationCenter.default.post(name: .captureLibraryCommand, object: "open")
        case .create:
            // A late model suggestion is a preview, never a new Return action.
            if routing.selection == .create || AdaptiveLauncherIntent.resolve(query) == .create { tools.save() }
        // Capture always requires selecting the labeled action. Return on a
        // classifier transition must never unexpectedly start a recording.
        default: break
        }
    }

    private func moveResult(_ command: String) -> KeyPress.Result {
        guard effectiveIntent == .search else { return .ignored }
        NotificationCenter.default.post(name: .captureLibraryCommand, object: command)
        return .handled
    }
}
