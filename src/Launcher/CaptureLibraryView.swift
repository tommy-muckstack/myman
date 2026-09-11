import AppKit
import SwiftUI

struct HighlightedCaptureText: View {
    let text: String
    var terms: [String] = []
    private var highlighted: AttributedString {
        var value = AttributedString(text)
        for term in terms where !term.isEmpty {
            var remaining = text.startIndex..<text.endIndex
            while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) {
                    value[lower..<upper].backgroundColor = MM.Colors.accent.opacity(0.3)
                    value[lower..<upper].foregroundColor = MM.Colors.textPrimary
                }
                remaining = range.upperBound..<text.endIndex
            }
        }
        return value
    }
    var body: some View { Text(highlighted) }
}

struct CaptureThumbnail: View {
    let path: String
    var revision: Int = 0
    var width: CGFloat = 48
    var height: CGFloat = 38
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(MM.Colors.textTertiary) }
        }
        .frame(width: width, height: height)
        .background(MM.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .task(id: "\(path):\(revision)") {
            let loaded = await Task.detached(priority: .utility) { CaptureThumbnailCache.load(path: path, size: max(100, Int(width * 2))) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct CaptureResultRow: View {
    let match: CaptureMatch
    var selected = false
    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            if match.item.kind == "screenshot" { CaptureThumbnail(path: match.item.sourcePath, revision: match.item.revision) }
            else { IconView(icon: match.item.icon).frame(width: 48) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    HighlightedCaptureText(text: match.item.title, terms: match.matchedTerms).font(MM.Fonts.body).lineLimit(1)
                    if match.item.pinned { Image(systemName: "pin.fill").foregroundStyle(MM.Colors.accent) }
                }
                HighlightedCaptureText(text: match.excerpt, terms: match.matchedTerms)
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).lineLimit(2)
                HStack {
                    Text(match.reason)
                    Spacer()
                    Text(match.item.capturedAt.formatted(date: .abbreviated, time: .shortened))
                }.font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
        }
        .padding(MM.Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).fill(selected ? MM.Colors.surface : .clear))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(selected ? MM.Colors.border : .clear))
        .foregroundStyle(MM.Colors.textPrimary)
        .accessibilityElement(children: .combine)
    }
}

extension Notification.Name { static let captureLibraryCommand = Notification.Name("man.captureLibraryCommand") }

struct CaptureLibraryView: View {
    @Binding var query: String
    @Binding var mode: CaptureLibraryMode
    var onDismiss: () -> Void = {}
    var onSaveQueryAsNote: (String) -> Void = { _ in }
    @StateObject private var model: CaptureLibraryModel
    init(query: Binding<String>, mode: Binding<CaptureLibraryMode>, onDismiss: @escaping () -> Void = {}, onSaveQueryAsNote: @escaping (String) -> Void = { _ in }, model: CaptureLibraryModel? = nil) {
        _query = query; _mode = mode; self.onDismiss = onDismiss
        self.onSaveQueryAsNote = onSaveQueryAsNote
        _model = StateObject(wrappedValue: model ?? CaptureLibraryModel())
    }
    @State private var kind = "all"
    @State private var period = "any"
    @State private var themeID = ""
    @State private var pinned = false
    @State private var includeExcluded = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showDates = false
    @State private var dateAnchor = Date()
    @State private var selectedThemeID: String?

    private var filter: CaptureFilter {
        var result = CaptureFilter(kind: kind, themeID: themeID.isEmpty ? nil : themeID, pinnedOnly: pinned, includeExcluded: includeExcluded)
        switch period {
        case "today": result.after = Calendar.current.startOfDay(for: dateAnchor)
        case "week": result.after = Calendar.current.date(byAdding: .day, value: -7, to: dateAnchor)
        case "month": result.after = Calendar.current.date(byAdding: .day, value: -30, to: dateAnchor)
        case "custom":
            result.after = Calendar.current.startOfDay(for: min(customStart, customEnd))
            result.before = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(customStart, customEnd)))
        default: break
        }
        return result
    }
    private var visibleThemes: [CaptureTheme] {
        guard !query.isEmpty else { return model.themes }
        let terms = CaptureText.words(CaptureQuery.resolve(query, filter: filter).text)
        return model.themes.filter { theme in model.matchingThemeIDs.contains(theme.id) || terms.allSatisfy { (theme.title + " " + theme.description).localizedCaseInsensitiveContains($0) } }
    }
    var body: some View {
        VStack(spacing: 0) {
            if mode != .themes { filters }
            if let hint = model.queryHint { Text(hint).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary).padding(.horizontal, MM.Layout.padding) }
            if mode != .themes, period == "custom" {
                HStack {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("Through", selection: $customEnd, displayedComponents: .date)
                }.font(MM.Fonts.secondary).padding(.horizontal, MM.Layout.padding)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if mode == .themes {
                            ForEach(visibleThemes) { theme in themeRow(theme).id(theme.id).background(selectedThemeID == theme.id ? MM.Colors.surface : .clear) }
                            if visibleThemes.isEmpty {
                                Text("Themes appear when several captures share a topic. Keep capturing; there’s nothing to organize by hand.")
                                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).padding(MM.Layout.padding)
                            }
                        } else {
                            if !query.isEmpty, themeID.isEmpty {
                                ForEach(Array(visibleThemes.prefix(3))) { theme in themeRow(theme) }
                            }
                            ForEach(model.results) { match in
                                CaptureResultRow(match: match, selected: model.selectedID == match.id)
                                    .id(match.id).clickable()
                                    .onTapGesture { model.selectedID = match.id }
                                    .onTapGesture(count: 2) { open(match) }
                                    .contextMenu { itemMenu(match.item) }
                            }
                            if model.results.isEmpty, !model.working {
                                Text(model.error ?? (query.isEmpty ? "Your intentional captures will appear here." : "No matches yet. Try a shorter phrase or a different filter."))
                                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).padding(MM.Layout.padding)
                                if !query.isEmpty { Button("Save as note ↵") { onDismiss(); onSaveQueryAsNote(query) }.buttonStyle(.plain).clickable().padding(.horizontal, MM.Layout.padding) }
                            }
                            if model.hasMore { Button("Show more") { reload(more: true) }.buttonStyle(.plain).clickable().padding(MM.Layout.padding) }
                        }
                    }.padding(8)
                }
                .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: selectedThemeID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            Divider().overlay(MM.Colors.border)
            HStack(spacing: MM.Layout.spacing) {
                if mode != .themes, let selected = model.selected {
                    Button("Open ↵") { open(selected) }.keyboardShortcut(.return, modifiers: []).clickable()
                    Button("Preview ⌘Y") { CaptureDetailController.shared.open(selected.item, query: query) }.keyboardShortcut("y", modifiers: .command).clickable()
                    Button("Copy ⇧⌘C") { CaptureActions.copy(selected.item) }.keyboardShortcut("c", modifiers: [.shift, .command]).clickable()
                }
                Spacer()
                if model.working { ProgressView().controlSize(.small).help("Finding related matches") }
                Text(mode == .themes ? "\(visibleThemes.count) themes" : "\(model.results.count) items").foregroundStyle(MM.Colors.textTertiary)
            }
            .font(MM.Fonts.metadata).buttonStyle(.plain).padding(MM.Layout.spacing)
        }
        .frame(height: 440)
        .onAppear { reload() }
        .onDisappear { model.cancel() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: filter) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryCommand)) { event in
            if mode == .themes {
                let index = visibleThemes.firstIndex { $0.id == selectedThemeID } ?? -1
                if event.object as? String == "open", let theme = visibleThemes.first(where: { $0.id == selectedThemeID }) ?? visibleThemes.first { themeID = theme.id; query = ""; mode = .history }
                else if !visibleThemes.isEmpty {
                    let delta = event.object as? String == "up" ? -1 : 1
                    selectedThemeID = visibleThemes[min(max(0, index + delta), visibleThemes.count - 1)].id
                }
                return
            }
            switch event.object as? String {
            case "down": model.move(1)
            case "up": model.move(-1)
            case "open":
                if let selected = model.selected { open(selected) }
                else if !query.isEmpty, !model.working { onDismiss(); onSaveQueryAsNote(query) }
            default: break
            }
        }
    }
    private var filters: some View {
        HStack(spacing: 6) {
            Picker("Content", selection: $kind) {
                Text("All").tag("all"); Text("Screenshots").tag("screenshot"); Text("Meetings").tag("meeting")
                Text("Dictation").tag("dictation"); Text("Recordings").tag("recording"); Text("Notes").tag("note")
            }.frame(width: 125)
            Picker("Date", selection: $period) {
                Text("Any time").tag("any"); Text("Today").tag("today"); Text("Last 7 days").tag("week")
                Text("Last 30 days").tag("month"); Text("Date range…").tag("custom")
            }.frame(width: 130)
            Picker("Theme", selection: $themeID) {
                Text("All themes").tag("")
                ForEach(model.themes) { Text($0.title).tag($0.id) }
            }.frame(maxWidth: 190)
            Button { pinned.toggle() } label: { Image(systemName: pinned ? "pin.fill" : "pin").clickable() }.help("Pinned captures")
            Menu {
                Toggle("Include hidden captures", isOn: $includeExcluded)
                Button("Clear capture history…") {
                    let alert = NSAlert(); alert.messageText = "Clear all capture history?"
                    alert.informativeText = "This deletes notes, dictations, meetings, screenshots and recordings, including local indexes and themes. Media moves to Trash. Current Brain exports are removed; earlier Git history and backups may remain."
                    alert.addButton(withTitle: "Clear History"); alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { CaptureActions.perform { try CaptureLifecycle.clearHistory() } }
                }
            } label: { Image(systemName: "ellipsis").clickable() }.menuStyle(.borderlessButton).frame(width: 28)
        }.labelsHidden().pickerStyle(.menu).font(MM.Fonts.secondary).padding(MM.Layout.spacing)
    }
    private func reload(more: Bool = false) { model.reload(query: query, filter: filter, more: more) }
    private func open(_ match: CaptureMatch) { onDismiss(); CaptureActions.open(match.item, query: query) }

    private func themeRow(_ theme: CaptureTheme) -> some View {
        Button {
            themeID = theme.id; query = ""; mode = .history
        } label: {
            HStack(spacing: MM.Layout.spacing) {
                Image(systemName: "square.stack").foregroundStyle(MM.Colors.accent).frame(width: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HighlightedCaptureText(text: theme.title, terms: CaptureText.words(query)).font(MM.Fonts.body).lineLimit(2)
                    if !theme.description.isEmpty {
                        Text(theme.description).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary).lineLimit(1)
                    }
                    Text("Theme · \(theme.typeCounts)")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer()
                if theme.pinned { Image(systemName: "pin.fill").foregroundStyle(MM.Colors.accent) }
                Text(theme.latest.formatted(.relative(presentation: .named))).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }.padding(MM.Layout.spacing).frame(maxWidth: .infinity, alignment: .leading).clickable()
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Rename…") { CaptureActions.prompt(title: "Rename theme", value: theme.title) { try ThemeStore.rename(theme.id, title: $0) } }
                Button(theme.pinned ? "Unpin" : "Pin") { CaptureActions.perform { try ThemeStore.pin(theme.id, pinned: !theme.pinned) } }
                Menu("Merge into") { ForEach(model.themes.filter { $0.id != theme.id }) { target in Button(target.title) { CaptureActions.perform { try ThemeStore.merge(theme.id, into: target.id) } } } }
                Button("Dismiss theme") { CaptureActions.perform { try ThemeStore.dismiss(theme.id) } }
            }
    }
    @ViewBuilder private func itemMenu(_ item: CaptureItem) -> some View {
        Button("Open original") { CaptureActions.open(item, query: query) }
        Button("Preview & related") { CaptureDetailController.shared.open(item, query: query) }
        Button("Copy") { CaptureActions.copy(item) }
        Button(item.kind == "screenshot" ? "Copy detected text" : "Copy text") { CaptureActions.copy(item, textOnly: true) }
        Button(item.pinned ? "Unpin" : "Pin") { CaptureActions.perform { try CaptureLifecycle.pin(item) } }
        Button("Rename…") { CaptureActions.prompt(title: "Capture title", value: item.title) { try CaptureLifecycle.rename(item, title: $0) } }
        Menu("Assign to theme") { ForEach(model.themes) { theme in Button(theme.title) { CaptureActions.perform { try ThemeStore.assign(item.id, to: theme.id) } } } }
        if !themeID.isEmpty { Button("Remove from this theme") { CaptureActions.perform { try ThemeStore.assign(item.id, to: themeID, remove: true) } } }
        Button(item.excluded ? "Include in search" : "Hide from search & themes") { CaptureActions.perform { try CaptureLifecycle.exclude(item, excluded: !item.excluded) } }
        Divider()
        Button("Delete…") { CaptureActions.confirmDelete(item) }
    }
}
