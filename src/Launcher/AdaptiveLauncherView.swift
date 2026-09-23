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
    @State private var correctionLearner = DictationCorrectionLearner()
    @State private var dictatedPrefix = ""
    @State private var showingCommands = false
    @State private var routing = AdaptiveLauncherRouting()
    @StateObject private var filters = CaptureLibraryFilters()
    @State private var libraryMode: CaptureLibraryMode = .search
    @ObservedObject var tools = QuickToolsController.shared.model
    var reminders: ReminderStore? = nil
    @FocusState private var focused: Bool

    private var effectiveIntent: AdaptiveLauncherIntent {
        if showingCommands { return .commands }
        if let selection = routing.selection { return selection }
        if libraryMode != .search || filters.isBrowsing || filters.active { return .search }
        return routing.suggestion
    }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var resolvedAction: LauncherAction? {
        guard case .action(let id) = effectiveIntent, id != "quick_tools" else { return nil }
        return actions.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: effectiveIntent == .create ? (tools.tool.icon ?? .search) : (resolvedAction?.icon ?? .search))
                    .accessibilityHidden(true)
                TextField(showingCommands ? "Search commands…" : libraryMode == .themes ? "Search themes…" : "Speak or Type to Search or Create", text: Binding(get: { query }, set: {
                    guard query != $0 else { return }
                    voice.stop()
                    if $0.hasPrefix(dictatedPrefix) {
                        correctionLearner.edited(String($0.dropFirst(dictatedPrefix.count)))
                    } else { correctionLearner.cancel() }
                    if $0.hasPrefix("/") {
                        showingCommands = true
                        routing = AdaptiveLauncherRouting()
                        query = String($0.dropFirst())
                    } else {
                        query = $0
                        if $0.isEmpty { showingCommands = false; voice.startAutomatically() }
                    }
                }))
                    .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { moveResult("down") }
                    .onKeyPress(.upArrow) { moveResult("up") }
                    .onKeyPress(.escape) {
                        if libraryMode == .themes { clearInput(); return .handled }
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
                if !query.isEmpty {
                    Button { clearInput() } label: {
                        Text("Clear").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                            .padding(.horizontal, MM.Layout.spacing / 2)
                            .frame(minWidth: 60, minHeight: 28)
                            .contentShape(Rectangle()).clickable()
                    }.buttonStyle(.plain).accessibilityLabel("Clear input")
                } else {
                    if voice.phase == .listening {
                        WaveformBars(levels: voice.levels, color: MM.Colors.accent)
                            .frame(width: WaveformBars.compactWidth, height: 18)
                            .accessibilityLabel("Microphone sound level")
                    }
                    Button { voice.toggle() } label: {
                        IconView(icon: voice.enabled ? .mic : .micOff,
                                 color: voice.enabled ? MM.Colors.accent : MM.Colors.textTertiary).clickable()
                    }.buttonStyle(.plain)
                        .accessibilityLabel(voice.enabled ? "Mute microphone" : "Start listening")
                        .help(voice.enabled ? "Mute microphone · Stays muted until you turn it on" : "Turn microphone on · Remember this choice")
                    Button { toggleThemes() } label: {
                        IconView(icon: .themes, color: libraryMode == .themes || !filters.themeID.isEmpty
                                 ? MM.Colors.accent : MM.Colors.textTertiary).clickable()
                    }.buttonStyle(.plain).accessibilityLabel("Themes")
                        .accessibilityValue(libraryMode == .themes ? "Open" : "Closed")
                        .help(libraryMode == .themes ? "Close themes" : "Browse themes")
                    Button {
                        onDismiss(); SettingsController.shared.show()
                    } label: { IconView(icon: .settings).clickable() }
                        .buttonStyle(.plain).accessibilityLabel("Settings")
                }
            }.padding(MM.Layout.padding)

            if resolvedAction != nil {
                EmptyView()
            } else if showingCommands || !trimmed.isEmpty || effectiveIntent == .search {
                Divider().overlay(MM.Colors.border)
                routedContent
            } else {
                Divider().overlay(MM.Colors.border)
                AdaptiveQuickActions(actions: actions, libraryModel: libraryModel,
                                     onDismiss: onDismiss, onSaveQueryAsNote: onSaveQueryAsNote, onSelectTool: openTool)
            }
            if effectiveIntent != .create || !tools.tool.isTimer {
                QuickTimerStatus(model: tools)
            }
            if voice.phase != .off && voice.phase != .listening {
                HStack(spacing: MM.Layout.spacing) {
                    Text(voice.status).font(MM.Fonts.metadata)
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
        .onDisappear { voice.stop(); correctionLearner.cancel() }
        .onChange(of: voice.utterance) { _, utterance in
            if let utterance, voice.utterance?.id == utterance.id {
                dictatedPrefix = query.isEmpty ? "" : query + (query.last?.isWhitespace == true ? "" : " ")
                query = AdaptiveLauncherVoice.appending(utterance.text, to: query)
                correctionLearner.begin(utterance.text)
                let input = query
                // A completed, unambiguous spoken timer/reminder is a submit.
                // Search mode and command browsing must never schedule anything.
                if !showingCommands, routing.selection != .search, libraryMode == .search, !filters.active,
                   AdaptiveLauncherIntent.resolve(input) == .create {
                    let activity = QuickToolParser.parse(input)
                    Task { @MainActor in
                        guard voice.utterance?.id == utterance.id, query == input else { return }
                        if await tools.startActivity(activity, reminders: reminders) { activityStarted() }
                    }
                }
            }
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
            AdaptiveResultScroll { QuickToolCard(model: tools, onTyping: { voice.stop() }, onActivityStarted: activityStarted, reminders: reminders) }
        case .action(let id):
            if id == "quick_tools" {
                AdaptiveResultScroll { QuickToolMenu(onSelect: openTool) }
            } else if let action = actions.first(where: { $0.id == id }) {
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
            if action.id == "quick_tools" {
                voice.stop(); showingCommands = false; query = "quick tools"; routing.update(query)
            } else { onDismiss(); action.run() }
        } label: {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: action.icon)
                Text(action.title).font(MM.Fonts.body)
                if action.recording { RecordingDot() }
                Spacer()
            }.clickable()
        }.buttonStyle(.plain).disabled(!action.enabled)
    }

    private func toggleThemes() {
        if libraryMode == .themes { clearInput(); return }
        voice.stop()
        correctionLearner.cancel()
        showingCommands = false
        routing = AdaptiveLauncherRouting()
        filters.reset()
        libraryMode = .themes
        focused = true
    }

    private func clearInput() {
        voice.stop()
        correctionLearner.cancel()
        dictatedPrefix = ""
        showingCommands = false
        routing = AdaptiveLauncherRouting()
        filters.reset(); libraryMode = .search
        query = ""
        tools.update("")
        focused = true
        voice.startAutomatically()
    }

    private func openTool(_ input: String) {
        voice.stop(); correctionLearner.cancel()
        showingCommands = false
        filters.reset(); libraryMode = .search
        routing.selection = .create
        query = input
        tools.update(AdaptiveLauncherIntent.creationText(input))
        focused = true
    }

    private func submit() {
        switch effectiveIntent {
        case .search:
            NotificationCenter.default.post(name: .captureLibraryCommand, object: "open")
        case .create:
            // A late model suggestion is a preview, never a new Return action.
            if routing.selection == .create || AdaptiveLauncherIntent.resolve(query) == .create {
                switch tools.tool {
                case .timer, .reminder:
                    Task { @MainActor in if await tools.startActivity(reminders: reminders) { activityStarted() } }
                default: tools.save()
                }
            }
        // Capture always requires selecting the labeled action. Return on a
        // classifier transition must never unexpectedly start a recording.
        default: break
        }
    }

    private func activityStarted() {
        voice.stop()
        onDismiss()
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
