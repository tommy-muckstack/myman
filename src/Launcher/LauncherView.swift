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
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }

    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedAction: Int?
    @State private var selectedResult: Int?
    @State private var hoveredAction: String?
    @State private var recentHits: [SearchHit] = []
    /// On open, every tile's hotkey shows briefly, then fades (hover recalls it).
    @State private var showAllHints = false
    @State private var copiedMeetingID: String?
    @State private var hoveredRowID: String?
    @State private var copiedRowID: String?
    @State private var rowsSettled = false
    @FocusState private var focused: Bool

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().overlay(MM.Colors.border)
            if searching {
                if results.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            } else {
                VStack(spacing: 0) {
                    actionBar
                    if !recentHits.isEmpty {
                        Divider().overlay(MM.Colors.border)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(recentHits) { hit in
                                resultRow(hit, selected: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(hit) }
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredRowID = hit.id
                                            NSCursor.pointingHand.set()
                                        } else {
                                            if hoveredRowID == hit.id { hoveredRowID = nil }
                                            NSCursor.arrow.set()
                                        }
                                    }
                                    .opacity(rowsSettled ? 1 : 0)
                                    .offset(y: rowsSettled ? 0 : -6)
                            }
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                // Recents stay open while the cursor is anywhere in this
                // section (bar OR list) — clearing on chip-exit would make
                // the list unreachable.
                .onHover { hovering in
                    if !hovering {
                        hoveredAction = nil
                        recentHits = []
                        rowsSettled = false
                    }
                }
            }
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
            results = []
            selectedAction = nil
            selectedResult = nil
            focused = true
            showAllHints = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(MM.Motion.gentle) { showAllHints = false }
            }
        }
        .onChange(of: query) { _, newValue in
            selectedResult = nil
            selectedAction = nil
            searchTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else {
                results = []
                return
            }
            // Debounce 120ms, then query off the main thread — typing never
            // waits on SQLite, and stale results never overwrite fresh ones.
            searchTask = Task { [query = newValue] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let hits = await Task.detached(priority: .userInitiated) {
                    SearchHit.searchDebounced(query)
                }.value
                guard !Task.isCancelled else { return }
                results = hits
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)

    }

    private var searchField: some View {
        HStack(spacing: MM.Layout.spacing) {
            IconView(icon: .search, size: 16, color: MM.Colors.textTertiary)
            TextField("", text: $query, prompt: Text("My man, what can I help with?")
                .foregroundStyle(MM.Colors.textTertiary))
                .textFieldStyle(.plain)
                .font(MM.Fonts.bodyInput)
                .foregroundStyle(MM.Colors.textPrimary)
                .focused($focused)
                .onKeyPress(.rightArrow) { moveAction(1) }
                .onKeyPress(.leftArrow) { moveAction(-1) }
                .onKeyPress(.tab) { _ = moveAction(1); return .handled }
                .onKeyPress(.downArrow) { moveResult(1); return .handled }
                .onKeyPress(.upArrow) { moveResult(-1); return .handled }
                .onKeyPress(.return) { execute(); return .handled }
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
    }

    // MARK: Search results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                resultRow(hit, selected: selectedResult == index)
                    .contentShape(Rectangle())
                    .onTapGesture { open(hit) }
                    .onHover { hovering in
                        if hovering {
                            selectedResult = index
                            hoveredRowID = hit.id
                            NSCursor.pointingHand.set()
                        } else {
                            if hoveredRowID == hit.id { hoveredRowID = nil }
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
        .padding(8)
    }

    private func kindBadge(_ hit: SearchHit) -> some View {
        Text(hit.kindLabel)
            .font(MM.Fonts.metadata)
            .foregroundStyle(MM.Colors.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(MM.Colors.surface))
            .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 0.5))
    }

    /// Hover actions shared by every row: Open (what clicking does) + Copy
    /// (contents to clipboard, no navigation).
    private func rowActions(_ hit: SearchHit) -> some View {
        HStack(spacing: 4) {
            Button {
                copyHit(hit)
            } label: {
                Group {
                    if copiedRowID == hit.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        IconView(icon: .copy, size: 13, color: MM.Colors.textSecondary)
                    }
                }
                .clickable(minSize: 24)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")

            Button {
                open(hit)
            } label: {
                IconView(icon: .open, size: 13, color: MM.Colors.textSecondary)
                    .clickable(minSize: 24)
            }
            .buttonStyle(.plain)
            .help("Open")

            Button {
                deleteHit(hit)
            } label: {
                IconView(icon: .trash, size: 13, color: MM.Colors.textSecondary)
                    .clickable(minSize: 24)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .fill(MM.Colors.surface)
        )
    }

    private func deleteHit(_ hit: SearchHit) {
        switch hit {
        case .note(let note):
            NotesStore().delete(note)
        case .screenshot(let shot):
            // File goes to the Trash (recoverable); the row goes away.
            try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: shot.path), resultingItemURL: nil)
            try? Database.shared.write { _ = try Screenshot.deleteOne($0, key: shot.id) }
            Brain.deleteScreenshot(id: shot.id, createdAt: shot.createdAt)
        case .meeting(let meeting):
            if let path = meeting.micAudioPath {
                try? FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            if let path = meeting.systemAudioPath {
                try? FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            for path in meeting.slidePaths {
                try? FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            try? Database.shared.write { _ = try Meeting.deleteOne($0, key: meeting.id) }
            Brain.deleteMeeting(id: meeting.id, startedAt: meeting.startedAt)
        case .dictation(let record):
            try? Database.shared.write {
                try $0.execute(sql: "DELETE FROM dictation WHERE id = ?", arguments: [record.id])
            }
        case .recording(let recording):
            try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: recording.path), resultingItemURL: nil)
            try? Database.shared.write { _ = try ScreenRecording.deleteOne($0, key: recording.id) }
            Brain.deleteRecording(id: recording.id, createdAt: recording.createdAt)
        }
        results.removeAll { $0.id == hit.id }
        recentHits.removeAll { $0.id == hit.id }
        Analytics.track("row_deleted")
    }

    private func copyHit(_ hit: SearchHit) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch hit {
        case .note(let note):
            pasteboard.setString(MarkdownRich.plainText(note.body), forType: .string)
        case .dictation(let dictation):
            pasteboard.setString(dictation.text, forType: .string)
        case .meeting(let meeting):
            pasteboard.setString(meeting.transcript, forType: .string)
        case .screenshot(let shot):
            if let image = NSImage(contentsOfFile: shot.path) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.setString(shot.path, forType: .string)
            }
        case .recording(let recording):
            pasteboard.writeObjects([URL(fileURLWithPath: recording.path) as NSURL])
        }
        Analytics.track("row_copied", ["kind": hit.kindLabel])
        copiedRowID = hit.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedRowID == hit.id { copiedRowID = nil }
        }
    }

    @ViewBuilder
    private func resultRow(_ hit: SearchHit, selected: Bool) -> some View {
        HStack(spacing: MM.Layout.spacing) {
            switch hit {
            case .note(let note):
                IconView(icon: .note, size: 16, color: MM.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                    Text(MarkdownRich.plainText(note.body).replacingOccurrences(of: "\n", with: "  "))
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    kindBadge(hit)
                    Text(note.updatedAt.formatted(.relative(presentation: .named)))
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                .opacity(hoveredRowID == hit.id || copiedRowID == hit.id ? 0 : 1)

            case .screenshot(let shot):
                IconView(icon: .screenshot, size: 16, color: MM.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screenshot")
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                    Text(shot.ocrText.split(separator: "\n").first.map(String.init) ?? "")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    kindBadge(hit)
                    Text(shot.createdAt.formatted(.relative(presentation: .named)))
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                .opacity(hoveredRowID == hit.id || copiedRowID == hit.id ? 0 : 1)

            case .recording(let recording):
                IconView(icon: .recordScreen, size: 16, color: MM.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recording.title)
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                    Text("\(recording.duration / 60):\(String(format: "%02d", recording.duration % 60)) · screen recording")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    kindBadge(hit)
                    Text(recording.createdAt.formatted(.relative(presentation: .named)))
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                .opacity(hoveredRowID == hit.id || copiedRowID == hit.id ? 0 : 1)

            case .dictation(let dictation):
                IconView(icon: .voice, size: 16, color: MM.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dictation.text.replacingOccurrences(of: "\n", with: "  "))
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                    Text(copiedMeetingID == dictation.id ? "Copied" : "Dictation")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    kindBadge(hit)
                    Text(dictation.createdAt.formatted(.relative(presentation: .named)))
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                .opacity(hoveredRowID == hit.id || copiedRowID == hit.id ? 0 : 1)

            case .meeting(let meeting):
                IconView(icon: .calendar, size: 16, color: MM.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                    Text(meeting.transcript.replacingOccurrences(of: "\n", with: "  "))
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    kindBadge(hit)
                    Text(meeting.startedAt.formatted(.relative(presentation: .named)))
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                .opacity(hoveredRowID == hit.id || copiedRowID == hit.id ? 0 : 1)
            }
        }
        .padding(.horizontal, MM.Layout.spacing)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .fill(selected ? MM.Colors.surface : .clear)
        )
        .overlay(alignment: .trailing) {
            if hoveredRowID == hit.id || copiedRowID == hit.id {
                rowActions(hit)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing for “\(query.trimmingCharacters(in: .whitespaces))”")
                .font(MM.Fonts.body)
                .foregroundStyle(MM.Colors.textSecondary)
            HStack(spacing: 5) {
                Text("⏎")
                    .font(MM.Fonts.metadata)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(MM.Colors.surface))
                Text("save it as a note")
                    .font(MM.Fonts.secondary)
            }
            .foregroundStyle(MM.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MM.Layout.padding)
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
                                NSCursor.pointingHand.set()
                            }
                            // Container + window resize INSTANTLY (anchored);
                            // then the rows ease into the opened space.
                            recentHits = SearchHit.recentItems(for: action.id)
                            rowsSettled = false
                            Task { @MainActor in
                                withAnimation(.easeOut(duration: 0.22)) { rowsSettled = true }
                            }
                        } else {
                            if hoveredAction == action.id {
                                // Hover owns selection; leaving clears it so
                                // nothing looks highlighted at rest. (The
                                // recents list is cleared by the CONTAINER's
                                // hover exit, so it survives the cursor
                                // moving down into it.)
                                if selectedAction == index { selectedAction = nil }
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
                .animation(.easeInOut(duration: 0.16), value: hintVisible)
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
        guard query.isEmpty else { return .ignored }
        let enabledIndices = actions.indices.filter { actions[$0].enabled }
        guard !enabledIndices.isEmpty else { return .handled }
        if let current = selectedAction, let position = enabledIndices.firstIndex(of: current) {
            selectedAction = enabledIndices[(position + delta + enabledIndices.count) % enabledIndices.count]
        } else {
            selectedAction = delta > 0 ? enabledIndices.first : enabledIndices.last
        }
        return .handled
    }

    private func moveResult(_ delta: Int) {
        guard searching, !results.isEmpty else { return }
        if let current = selectedResult {
            selectedResult = min(max(0, current + delta), results.count - 1)
        } else if delta > 0 {
            selectedResult = 0
        }
    }

    private func execute() {
        if searching {
            if let index = selectedResult, results.indices.contains(index) {
                open(results[index])
            } else if results.isEmpty {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                onDismiss()
                onSaveQueryAsNote(text)
            } else {
                open(results[0])
            }
            return
        }
        guard let index = selectedAction, actions.indices.contains(index),
              actions[index].enabled else { return }
        let action = actions[index]
        onDismiss()
        action.run()
    }

    private func open(_ hit: SearchHit) {
        let rank = results.firstIndex(where: { $0.id == hit.id }) ?? -1
        SearchService.recordClick(query: query, hit: hit, rank: rank, resultCount: results.count)
        switch hit {
        case .note(let note):
            onDismiss()
            onOpenNote(note)
        case .screenshot(let shot):
            onDismiss()
            onOpenScreenshot(URL(fileURLWithPath: shot.path))
        case .meeting(let meeting):
            onDismiss()
            MeetingDocumentController.shared.open(meetingID: meeting.id)
        case .dictation(let dictation):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dictation.text, forType: .string)
            copiedMeetingID = dictation.id
        case .recording(let recording):
            onDismiss()
            NSWorkspace.shared.open(URL(fileURLWithPath: recording.path))
        }
    }
}


extension SearchHit {
    /// Runs on a background task from the launcher's debounced onChange —
    /// FTS + cached embeddings keep this fast at any corpus size.
    static func searchDebounced(_ query: String) -> [SearchHit] {
        SearchService.search(query)
    }
}

extension SearchHit {
    static func recentItems(for actionID: String) -> [SearchHit] {
        SearchService.recent(kind: actionID == "voice" ? "voice" : actionID)
    }
}
