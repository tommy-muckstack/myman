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
    @State private var showingCommands = false
    @State private var routing = AdaptiveLauncherRouting()
    @StateObject private var filters = CaptureLibraryFilters()
    @State private var libraryMode: CaptureLibraryMode = .search
    @ObservedObject var tools = QuickToolsController.shared.model
    @FocusState private var focused: Bool

    private var effectiveIntent: AdaptiveLauncherIntent {
        if showingCommands { return .commands }
        if let selection = routing.selection { return selection }
        if libraryMode != .search || filters.isBrowsing || filters.active { return .search }
        return routing.suggestion
    }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolvedAction: LauncherAction? {
        guard case .action(let id) = effectiveIntent else { return nil }
        return actions.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MM.Layout.spacing) {
                if effectiveIntent == .create, let icon = tools.tool.icon { IconView(icon: icon) }
                TextField(showingCommands ? "Search commands…" : "Find something or make something…", text: Binding(get: { query }, set: {
                    guard query != $0 else { return }
                    voice.stop()
                    if $0.hasPrefix("/") {
                        showingCommands = true
                        routing = AdaptiveLauncherRouting()
                        query = String($0.dropFirst())
                    } else { query = $0 }
                }))
                    .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { moveResult("down") }
                    .onKeyPress(.upArrow) { moveResult("up") }
                    .onKeyPress(.escape) {
                        guard showingCommands else { return .ignored }
                        showingCommands = false; query = ""
                        return .handled
                    }
                if let action = resolvedAction {
                    Button {
                        onDismiss(); action.run()
                    } label: {
                        Text(action.recording ? "Stop" : action.id == "screenshot" ? "Capture" : action.id == "quick_tools" ? "Open" : "Start")
                            .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.onAccent)
                            .padding(.horizontal, MM.Layout.padding).padding(.vertical, MM.Layout.spacing / 2)
                            .background(MM.Colors.accent, in: Capsule()).clickable()
                    }.buttonStyle(.plain).disabled(!action.enabled).accessibilityLabel(action.title).help(action.title)
                }
                if !trimmed.isEmpty, effectiveIntent == .search || effectiveIntent == .create {
                    Menu {
                        if effectiveIntent == .create, tools.tool.canSave, !tools.tool.isTimer {
                            Button("Copy result") { tools.copy() }
                            Button("Save to Notes") { tools.save() }
                            Divider()
                        }
                        Button("Search existing") { select(.search) }
                        Button("Create new") { select(.create) }
                    } label: {
                        IconView(icon: .more, color: MM.Colors.textTertiary).clickable()
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Request options").help("Request options")
                }
                if effectiveIntent == .search { CaptureFilterMenu(mode: $libraryMode, filters: filters) }
                Button { voice.toggle() } label: {
                    IconView(icon: voice.enabled ? .mic : .micOff,
                             color: voice.enabled ? MM.Colors.accent : MM.Colors.textTertiary).clickable()
                }.buttonStyle(.plain)
                    .accessibilityLabel(voice.enabled ? "Pause listening for one hour" : "Start listening")
                    .help(voice.enabled ? voice.status + " · Pause for 1 hour" : "Start listening · Clears any listening pause")
                Button {
                    onDismiss(); SettingsController.shared.show()
                } label: { IconView(icon: .settings).clickable() }
                    .buttonStyle(.plain).accessibilityLabel("Settings")
            }.padding(MM.Layout.padding)

            if resolvedAction != nil {
                EmptyView()
            } else if showingCommands || !trimmed.isEmpty || effectiveIntent == .search {
                Divider().overlay(MM.Colors.border)
                routedContent
            } else {
                Divider().overlay(MM.Colors.border)
                AdaptiveQuickActions(actions: actions, libraryModel: libraryModel,
                                     onDismiss: onDismiss, onSaveQueryAsNote: onSaveQueryAsNote)
                HStack {
                    Text("Type / for actions and tools").font(MM.Fonts.metadata)
                    Spacer()
                    Button("Browse library") { routing.selection = .search; query = "find " }
                        .font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
                }.foregroundStyle(MM.Colors.textTertiary)
                    .padding(.horizontal, MM.Layout.padding).padding(.bottom, MM.Layout.spacing)
            }
            if effectiveIntent != .create || !tools.tool.isTimer {
                QuickTimerStatus(model: tools)
            }
            if voice.phase != .off {
                HStack(spacing: MM.Layout.spacing) {
                    Text(voice.status).font(MM.Fonts.metadata)
                    if voice.phase == .listening {
                        WaveformBars(levels: voice.levels)
                            .frame(width: WaveformBars.compactWidth, height: 18)
                            .accessibilityLabel("Microphone sound level")
                    }
                    if voice.phase == .denied {
                        Button("Microphone settings") { Permission.microphone.request() }
                            .font(MM.Fonts.metadata).buttonStyle(.plain).clickable()
                    }
                }.foregroundStyle(MM.Colors.textSecondary)
                    .padding(.horizontal, MM.Layout.padding).padding(.bottom, MM.Layout.spacing)
            }
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
        .onAppear {
            showingCommands = initialQuery.hasPrefix("/")
            query = showingCommands ? String(initialQuery.dropFirst()) : initialQuery
            focused = true
        }
        .onDisappear { voice.stop() }
        .onChange(of: voice.utterance) { _, utterance in
            if voice.enabled, let utterance { query = AdaptiveLauncherVoice.appending(utterance.text, to: query) }
        }
        .onChange(of: query) { _, value in
            routing.update(value)
            if trimmed.isEmpty || trimmed == "/" { filters.reset(); libraryMode = .search }
            tools.update(AdaptiveLauncherIntent.creationText(value))
        }
        .task(id: query) {
            let input = query
            guard !showingCommands, routing.selection == nil, AdaptiveLauncherIntent.resolve(input) == .choose, !input.isEmpty else { return }
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
            AdaptiveResultScroll { QuickToolCard(model: tools, onTyping: { voice.stop() }) }
        case .action(let id):
            if let action = actions.first(where: { $0.id == id }) {
                actionButton(action).padding(MM.Layout.padding)
            } else {
                Text("This action isn’t available on this Mac.").font(MM.Fonts.body).padding(MM.Layout.padding)
            }
        case .tasks: TasksPanelView(inline: true)
        case .calendar: CalendarPanelView(inline: true)
        case .commands:
            AdaptiveResultScroll {
                VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                    ForEach(actions.filter { matchesCommand($0.title + " " + $0.id) }) { action in actionButton(action) }
                    if matchesCommand("My tasks") {
                        Button("My tasks") { showingCommands = false; query = "my tasks" }.buttonStyle(.plain).clickable()
                    }
                    if matchesCommand("My calendar") {
                        Button("My calendar") { showingCommands = false; query = "my calendar" }.buttonStyle(.plain).clickable()
                    }
                    ForEach(["Calculator", "Reminder"], id: \.self) { title in
                        if matchesCommand(title) {
                            Button { showingCommands = false; query = title.lowercased() } label: {
                                HStack(spacing: MM.Layout.spacing) {
                                    IconView(icon: title == "Calculator" ? .calculator : .reminder)
                                    Text(title)
                                    Spacer()
                                }.clickable()
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(QuickToolParser.examples.filter(matchesCommand), id: \.self) { example in
                        Button(example) { showingCommands = false; query = example }.buttonStyle(.plain).clickable()
                    }
                    if !actions.contains(where: { matchesCommand($0.title + " " + $0.id) }),
                       !matchesCommand("My tasks"), !matchesCommand("My calendar"),
                       !matchesCommand("Calculator"), !matchesCommand("Reminder"),
                       !QuickToolParser.examples.contains(where: matchesCommand) {
                        Text("No matching commands").foregroundStyle(MM.Colors.textTertiary)
                    }
                }.font(MM.Fonts.body).padding(MM.Layout.padding).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .choose:
            HStack(spacing: MM.Layout.spacing) {
                modeButton("Search existing", intent: .search)
                modeButton("Create new", intent: .create)
                Spacer()
            }.font(MM.Fonts.secondary).padding(MM.Layout.padding)
        }
    }

    private func matchesCommand(_ title: String) -> Bool {
        trimmed.isEmpty || trimmed.split(whereSeparator: \.isWhitespace).allSatisfy { title.localizedCaseInsensitiveContains(String($0)) }
    }

    private func modeButton(_ title: String, intent: AdaptiveLauncherIntent) -> some View {
        Button {
            select(intent)
        } label: {
            Text(title).foregroundStyle(effectiveIntent == intent ? MM.Colors.textPrimary : MM.Colors.textSecondary)
                .padding(.horizontal, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing / 2)
                .background(effectiveIntent == intent ? MM.Colors.surface : .clear,
                            in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }.buttonStyle(.plain)
    }

    private func select(_ intent: AdaptiveLauncherIntent) {
        routing.selection = intent
        if intent == .create { filters.reset(); libraryMode = .search }
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
            if routing.selection == .create || AdaptiveLauncherIntent.resolve(query) == .create {
                if case .timer(let seconds) = tools.tool {
                    if !tools.timerActive { tools.start(seconds: seconds) }
                } else { tools.save() }
            }
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

/// Short results size the panel naturally; long notes and lists stay scrollable.
/// The controller defers window resizing out of SwiftUI's layout pass.
struct AdaptiveResultScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 1

    var body: some View {
        ScrollView {
            content().fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AdaptiveResultHeight.self, value: geometry.size.height)
                })
        }
        .frame(height: min(320, height))
        .onPreferenceChange(AdaptiveResultHeight.self) { height = max(1, $0) }
    }
}

private struct AdaptiveResultHeight: PreferenceKey {
    static var defaultValue: CGFloat { 1 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
