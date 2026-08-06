import AppKit
import SwiftUI

// A note is a document: click one anywhere and it opens in a small
// Paper-style window — styled markdown, ⌘B/⌘I, autosave. The quick-capture
// panel stays for creating; this is for living with them.

@MainActor
final class NoteDocumentController {
    static let shared = NoteDocumentController()
    private var windows: [String: NSWindow] = [:]

    func open(_ note: Note) {
        if let existing = windows[note.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.contentView = NSHostingView(rootView: NoteDocumentView(note: note))
        windows[note.id] = window
        Analytics.track("note_document_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Subtle autosave status: quiet "Saving…" while the debounce runs, a brief
/// "Saved" confirmation, then silence.
enum SaveState { case idle, pending, saved }

struct SaveIndicator: View {
    let state: SaveState

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .pending:
                Text("Saving…")
            case .saved:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Saved")
                }
            }
        }
        .font(MM.Fonts.metadata)
        .foregroundStyle(MM.Colors.textTertiary)
        .transition(.opacity)
        .animation(MM.Motion.gentle, value: state)
    }
}

struct NoteDocumentView: View {
    let note: Note
    @State private var body_: String
    @State private var saveTask: Task<Void, Never>?
    @State private var saveState: SaveState = .idle
    @State private var linkCopied = false
    @State private var headerHovering = false
    private let store = NotesStore()

    init(note: Note) {
        self.note = note
        _body_ = State(initialValue: note.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        Brain.noteFilePath(id: note.id, createdAt: note.createdAt),
                        forType: .string)
                    linkCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        linkCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        IconView(icon: .copy, size: 12,
                                 color: linkCopied ? .green : MM.Colors.textTertiary)
                        Text(linkCopied ? "Copied" : "Copy link")
                    }
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(linkCopied ? .green : MM.Colors.textTertiary)
                    .clickable(minSize: 22)
                }
                .buttonStyle(.plain)
                .opacity(headerHovering ? 1 : 0)
                .animation(MM.Motion.gentle, value: headerHovering)
                .help("Copy this note's file path — paste it to Claude or any agent")
                SaveIndicator(state: saveState)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .contentShape(Rectangle())
            .onHover { headerHovering = $0 }
            RichMarkdownEditor(markdown: $body_)
                .onChange(of: body_) { _, newValue in
                    saveTask?.cancel()
                    saveState = .pending
                    saveTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        store.update(note, body: newValue)
                        saveState = .saved
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        if saveState == .saved { saveState = .idle }
                    }
                }
        }
        .background(MM.Colors.background)
        .frame(minWidth: 380, minHeight: 300)
    }
}
