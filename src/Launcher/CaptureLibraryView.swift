import AppKit
import SwiftUI
import GRDB

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

private struct CaptureRowHighlight: ViewModifier {
    var keyboardFocused = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                .fill(hovered ? MM.Colors.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                .strokeBorder(keyboardFocused ? MM.Colors.textPrimary : hovered ? MM.Colors.border.opacity(0.5) : .clear, lineWidth: keyboardFocused ? 2 : 1)
                .allowsHitTesting(false))
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct CaptureResultRow: View {
    let match: CaptureMatch
    var database: DatabaseQueue? = nil
    var selected = false
    var keyboardFocused = false
    var onOpen: () -> Void = {}
    @State private var hovered = false
    private var showActions: Bool { hovered || keyboardFocused }
    private let actionsWidth: CGFloat = 104

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) { rowContent.clickable() }
                .buttonStyle(.plain)
            HStack(spacing: 4) {
                rowAction(.copy, label: "Copy", help: match.item.kind == "screenshot" ? "Copy image to clipboard" : "Copy to clipboard") {
                    copyCapture()
                }
                rowAction(.link, label: "Copy Path", help: "Copy file path") {
                    copyFilePath()
                }
                rowAction(.trash, label: "Delete", help: "Delete capture…", destructive: true) {
                    CaptureActions.confirmDelete(match.item)
                }
            }
            .frame(width: actionsWidth, alignment: .trailing)
            .padding(MM.Layout.spacing)
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
            .disabled(!showActions)
            .accessibilityHidden(!showActions)
        }
        .modifier(CaptureRowHighlight(keyboardFocused: keyboardFocused))
        .onHover { hovered = $0 }
        .onDisappear { hovered = false }
        .foregroundStyle(MM.Colors.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Copy") { copyCapture() }
        .accessibilityAction(named: "Copy Path") { copyFilePath() }
        .accessibilityAction(named: "Delete") { CaptureActions.confirmDelete(match.item) }
    }

    private func copyCapture() {
        Toast.show(CaptureActions.copy(match.item) ? "Copied to clipboard" : "Couldn’t copy this capture")
    }

    private func copyFilePath() {
        Toast.show(CaptureActions.copyPath(match.item) ? "File path copied" : "This capture’s file is not available yet")
    }

    private func rowAction(_ icon: MMIcon, label: String, help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon: icon, size: 14, color: destructive ? MM.Colors.danger : MM.Colors.textSecondary)
                .frame(width: 32, height: 28)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private var rowContent: some View {
        HStack(spacing: MM.Layout.spacing) {
            CaptureResultThumbnail(item: match.item, database: database)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    HighlightedCaptureText(text: match.item.title, terms: match.matchedTerms).font(MM.Fonts.body).lineLimit(1)
                    if match.item.pinned { Image(systemName: "pin.fill").foregroundStyle(MM.Colors.accent) }
                }
                .padding(.trailing, actionsWidth + MM.Layout.spacing)
                .frame(minHeight: 28, alignment: .leading)
                HighlightedCaptureText(text: match.excerpt, terms: match.matchedTerms)
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).lineLimit(2)
                HStack {
                    Text(match.reason)
                    Spacer()
                    Text(match.item.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }.font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
        }
        .padding(MM.Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension Notification.Name { static let captureLibraryCommand = Notification.Name("man.captureLibraryCommand") }

struct CaptureLibraryView: View {
    @Binding var query: String
    @Binding var mode: CaptureLibraryMode
    var onDismiss: () -> Void = {}
    var onSaveQueryAsNote: (String) -> Void = { _ in }
    @ObservedObject private var controls: CaptureLibraryFilters
    @StateObject private var model: CaptureLibraryModel
    init(query: Binding<String>, mode: Binding<CaptureLibraryMode>, controls: CaptureLibraryFilters? = nil, onDismiss: @escaping () -> Void = {}, onSaveQueryAsNote: @escaping (String) -> Void = { _ in }, model: CaptureLibraryModel? = nil) {
        self.controls = controls ?? CaptureLibraryFilters()
        _query = query; _mode = mode; self.onDismiss = onDismiss
        self.onSaveQueryAsNote = onSaveQueryAsNote
        _model = StateObject(wrappedValue: model ?? CaptureLibraryModel())
    }
    private var kind: String { get { controls.displayedKind } nonmutating set { controls.actionKind = nil; controls.kind = newValue } }
    private var period: String { get { controls.period } nonmutating set { controls.period = newValue } }
    private var themeID: String { get { controls.themeID } nonmutating set { controls.themeID = newValue } }
    private var pinned: Bool { get { controls.pinned } nonmutating set { controls.pinned = newValue } }
    private var includeExcluded: Bool { get { controls.includeExcluded } nonmutating set { controls.includeExcluded = newValue } }
    private var customStart: Date { get { controls.customStart } nonmutating set { controls.customStart = newValue } }
    private var customEnd: Date { get { controls.customEnd } nonmutating set { controls.customEnd = newValue } }
    @State private var dateAnchor = Date()
    @State private var selectedThemeID: String?
    @State private var keyboardNavigation = false

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
            if !themeID.isEmpty, let theme = model.themes.first(where: { $0.id == themeID }) {
                HStack {
                    IconView(icon: .themes, size: 14, color: MM.Colors.accent)
                    Text(theme.title).font(MM.Fonts.secondary)
                    Spacer()
                    Button("All themes") { themeID = ""; mode = .themes }.buttonStyle(.plain).clickable()
                }.padding(MM.Layout.spacing)
            }
            if let hint = model.queryHint { Text(hint).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary).padding(.horizontal, MM.Layout.padding) }
            if mode != .themes, period == "custom" {
                HStack {
                    DatePicker("From", selection: $controls.customStart, displayedComponents: .date)
                    DatePicker("Through", selection: $controls.customEnd, displayedComponents: .date)
                }.font(MM.Fonts.secondary).padding(.horizontal, MM.Layout.padding)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if mode == .themes {
                            ForEach(visibleThemes) { theme in themeRow(theme).id(theme.id) }
                        } else {
                            if !query.isEmpty, themeID.isEmpty {
                                ForEach(Array(visibleThemes.prefix(3))) { theme in themeRow(theme) }
                            }
                            ForEach(model.results) { match in
                                CaptureResultRow(match: match, database: model.database, selected: model.selectedID == match.id,
                                                 keyboardFocused: keyboardNavigation && model.selectedID == match.id,
                                                 onOpen: { open(match) })
                                .id(match.id)
                                .contextMenu { itemMenu(match.item) }
                            }
                            if model.hasMore { Button("Show more") { reload(more: true) }.buttonStyle(.plain).clickable().padding(MM.Layout.padding) }
                        }
                    }.padding(8)
                }
                .overlay {
                    if !model.working {
                        if mode == .themes && visibleThemes.isEmpty {
                            UtilityEmptyState(icon: .themes, title: query.isEmpty ? "Ideas find each other" : "No themes found",
                                              message: query.isEmpty ? "Related captures will gather here." : "Try another word or a broader idea.")
                        } else if mode != .themes && model.results.isEmpty && (query.isEmpty || visibleThemes.isEmpty) {
                            libraryEmptyState
                        }
                    }
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
        .onChange(of: query) { _, _ in keyboardNavigation = false; reload() }
        .onChange(of: filter) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryCommand)) { event in
            if ["up", "down"].contains(event.object as? String ?? "") { keyboardNavigation = true }
            if mode == .themes {
                let index = visibleThemes.firstIndex { $0.id == selectedThemeID } ?? -1
                if event.object as? String == "open", let theme = visibleThemes.first(where: { $0.id == selectedThemeID }) ?? visibleThemes.first { openTheme(theme.id) }
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
    @ViewBuilder private var libraryEmptyState: some View {
        if model.error != nil {
            UtilityEmptyState(icon: .search, title: "Couldn't load your captures", message: "Let's give that another try.", actionTitle: "Try again") { reload() }
        } else if !query.isEmpty {
            UtilityEmptyState(icon: .search, title: "Still looking?", message: "Try another word or a wider date range.", actionTitle: "Save as note") {
                onDismiss(); onSaveQueryAsNote(query)
            }
        } else if kind != "all" || period != "any" || !themeID.isEmpty || pinned {
            UtilityEmptyState(icon: kind == "note" ? .note : .search, title: kind == "note" ? "Room for a thought" : "Nothing here just yet", message: kind == "note" ? "Your saved notes will find a home here." : "Try opening things up a little.", actionTitle: "Clear filters") {
                kind = "all"; period = "any"; themeID = ""; pinned = false
            }
        } else {
            UtilityEmptyState(icon: .note, title: "Keep something worth finding", message: "Your notes, meetings, and captures will live here.", actionTitle: "Write a note") {
                onDismiss(); NoteDocumentController.shared.create()
            }
        }
    }

    private func reload(more: Bool = false) { model.reload(query: query, filter: filter, more: more) }
    private func open(_ match: CaptureMatch) { onDismiss(); CaptureActions.open(match.item, query: query) }
    private func openTheme(_ id: String) { controls.showTheme(id); query = ""; mode = .search }

    private func themeRow(_ theme: CaptureTheme) -> some View {
        Button {
            openTheme(theme.id)
        } label: {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: .themes, color: MM.Colors.accent).frame(width: 48)
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
            }.padding(MM.Layout.spacing).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(CaptureRowHighlight(keyboardFocused: keyboardNavigation && selectedThemeID == theme.id))
                .accessibilityAddTraits(selectedThemeID == theme.id ? [.isSelected] : [])
                .clickable()
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
        if item.kind == "screenshot" {
            Button("Float as reference") { CaptureActions.perform { try FloatingReference.open(item) } }
        }
        if item.kind == "recording" { Button("Make agent brief…") { AgentBriefWindow.shared.open(recording: item) } }
        Button("Share…") { CaptureShare.open(item) }
        Button("Prepare context for Bot…") { WorkflowContext.show(item) }
        Button("Preview & related") { CaptureDetailController.shared.open(item, query: query) }
        Button("Copy") { CaptureActions.copy(item) }
        Button("Copy Path") {
            let copied = CaptureActions.copyPath(item)
            Toast.show(copied ? "File path copied" : "This capture’s file is not available yet")
        }
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
