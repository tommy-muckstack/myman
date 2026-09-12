import AppKit
import SwiftUI

// The My Man launcher: ⌥Space → one field, one horizontal row of actions.
// The moment you type, the actions step aside and universal search takes
// over — notes, screenshot OCR, meeting transcripts; keyword hits first,
// semantic matches beneath (all on-device). Empty state turns the query
// into a note with ⏎.

struct LauncherAction: Identifiable {
    let id: String
    let icon: MMIcon
    let title: String
    let hint: String?
    let enabled: Bool
    /// Shows a pulsing red dot on the tile (e.g. meeting recording live).
    var recording: Bool = false
    let run: () -> Void

    var captureKind: String? {
        switch id {
        case "screenshot", "note", "meeting": return id
        case "voice": return "dictation"
        case "record": return "recording"
        default: return nil
        }
    }
}

/// Small pulsing red indicator for in-progress recordings.
struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.25 : 0.8)
            .opacity(pulsing ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

struct LauncherView: View {
    let actions: [LauncherAction]
    var onOpenNote: (Note) -> Void
    var onOpenScreenshot: (URL) -> Void
    var onSaveQueryAsNote: (String) -> Void
    var onOpenChat: () -> Void
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }
    var libraryModel: CaptureLibraryModel? = nil

    @State private var query = ""
    @StateObject private var libraryFilters = CaptureLibraryFilters()
    @State private var libraryMode: CaptureLibraryMode = .search
    @State private var selectedAction: Int?
    @State private var hoveredAction: String?
    /// On open, every tile's hotkey shows briefly, then fades (hover recalls it).
    @State private var showAllHints = false
    /// Chat is deliberately a quiet beta: reveal its switch from the search
    /// icon, rather than giving it a launcher tile or a global shortcut.
    @State private var showChatSwitch = false
    @FocusState private var focused: Bool

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().overlay(MM.Colors.border)
            if !searching && libraryMode == .search { actionBar }
            CaptureLibraryView(query: $query, mode: $libraryMode, controls: libraryFilters, onDismiss: onDismiss, onSaveQueryAsNote: onSaveQueryAsNote, model: libraryModel)
        }
        .frame(width: MM.Layout.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
        )
        // Ground truth for the panel's size: what SwiftUI actually rendered.
        // (NSHostingView.fittingSize lies during state transitions.)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { onSizeChange(geo.size) }
                .onChange(of: geo.size) { _, newSize in onSizeChange(newSize) }
        })
        .onAppear {
            query = ""
            selectedAction = nil
            hoveredAction = nil
            libraryFilters.actionKind = nil
            showChatSwitch = false
            focused = true
            showAllHints = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // Shortcut labels are deliberately opacity-only. A spring here
                // makes them look as though they rise out of the tile.
                withAnimation(.easeInOut(duration: 0.16)) { showAllHints = false }
            }
        }
        .onChange(of: query) { _, _ in
            selectedAction = nil
            hoveredAction = nil
            libraryFilters.actionKind = nil
        }
        .onChange(of: libraryMode) { _, _ in
            selectedAction = nil
            hoveredAction = nil
            libraryFilters.actionKind = nil
        }
        .frame(maxHeight: .infinity, alignment: .top)

    }

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: .search, size: 16, color: MM.Colors.textTertiary)
                    .clickable()
                    .onTapGesture { focused = true; showChatSwitch = true }
                    .help("Search")
                TextField("", text: $query, prompt: Text("Find something you captured…")
                    .foregroundStyle(MM.Colors.textTertiary))
                    .textFieldStyle(.plain)
                    .font(MM.Fonts.bodyInput)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .focused($focused)
                    .onKeyPress(.rightArrow) { moveAction(1) }
                    .onKeyPress(.leftArrow) { moveAction(-1) }
                    .onKeyPress(.tab) { moveAction(1) }
                    .onKeyPress(.downArrow) { moveResult(1); return .handled }
                    .onKeyPress(.upArrow) { moveResult(-1); return .handled }
                    .onKeyPress(.return) { execute(); return .handled }
                CaptureFilterMenu(mode: $libraryMode, filters: libraryFilters)
                IconView(icon: .settings, size: 15, color: MM.Colors.textTertiary)
                    .clickable()
                    .onTapGesture {
                        onDismiss()
                        SettingsController.shared.show()
                    }
                    .help("Settings — hotkeys, folders")
            }
            .padding(.horizontal, MM.Layout.padding)
            .padding(.vertical, 14)
            if showChatSwitch {
                HStack {
                    Spacer()
                    Button("Switch to Chat β") { onOpenChat() }
                        .buttonStyle(.plain).font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                        .padding(.trailing, MM.Layout.padding)
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Action bar (only when not searching)

    private var actionBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                actionChip(action, selected: selectedAction == index)
                    .onTapGesture {
                        guard action.enabled else { return }
                        selectedAction = index
                        execute()
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredAction = action.id
                            if action.enabled {
                                selectedAction = index
                                libraryFilters.actionKind = action.captureKind
                                NSCursor.pointingHand.set()
                            }
                        } else {
                            if hoveredAction == action.id {
                                // Hover owns tile selection; leaving restores
                                // Return to the selected search result.
                                if selectedAction == index { selectedAction = nil }
                                hoveredAction = nil
                            }
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
        .padding(8)
    }

    private func actionChip(_ action: LauncherAction, selected: Bool) -> some View {
        let hintVisible = showAllHints || hoveredAction == action.id || (selected && action.enabled)
        return VStack(spacing: 4) {
            IconView(icon: action.icon, size: 17,
                     color: action.enabled ? MM.Colors.textPrimary : MM.Colors.textTertiary)
                .overlay(alignment: .topTrailing) {
                    if action.recording {
                        RecordingDot().offset(x: 8, y: -4)
                    }
                }
            Text(action.title)
                .font(MM.Fonts.hint)
                .foregroundStyle(action.enabled ? MM.Colors.textSecondary : MM.Colors.textTertiary)
                .lineLimit(1)
            // Fixed-height hint slot: the hotkey fades in on hover, the tile
            // never changes size.
            Text(action.enabled ? (action.hint ?? " ") : "soon")
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textTertiary)
                .lineLimit(1)
                .opacity(hintVisible ? 1 : 0)
                .transaction { $0.animation = .easeInOut(duration: 0.16) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .fill(selected && action.enabled ? MM.Colors.surface : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .strokeBorder(selected && action.enabled ? MM.Colors.border : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(action.enabled ? (action.hint ?? action.title) : "\(action.title) — coming soon")
    }

    // MARK: Keyboard & execution

    private func moveAction(_ delta: Int) -> KeyPress.Result {
        guard query.isEmpty, libraryMode == .search else { return .ignored }
        let enabledIndices = actions.indices.filter { actions[$0].enabled }
        guard !enabledIndices.isEmpty else { return .handled }
        if let current = selectedAction, let position = enabledIndices.firstIndex(of: current) {
            selectedAction = enabledIndices[(position + delta + enabledIndices.count) % enabledIndices.count]
        } else {
            selectedAction = delta > 0 ? enabledIndices.first : enabledIndices.last
        }
        if let index = selectedAction { libraryFilters.actionKind = actions[index].captureKind }
        return .handled
    }

    private func moveResult(_ delta: Int) {
        selectedAction = nil
        NotificationCenter.default.post(name: .captureLibraryCommand, object: delta > 0 ? "down" : "up")
    }

    private func execute() {
        if searching || libraryMode != .search || selectedAction == nil {
            NotificationCenter.default.post(name: .captureLibraryCommand, object: "open")
            return
        }
        guard let index = selectedAction, actions.indices.contains(index),
              actions[index].enabled else { return }
        let action = actions[index]
        onDismiss()
        action.run()
    }


}


extension SearchHit {
    static func recentItems(for actionID: String) -> [SearchHit] {
        SearchService.recent(kind: actionID == "voice" ? "voice" : actionID)
    }
}
