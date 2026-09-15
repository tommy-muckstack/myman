import AppKit
import SwiftUI

// A note is a document: click one anywhere and it opens in a small
// Paper-style window — styled markdown, ⌘B/⌘I, autosave. The quick-capture
// panel stays for creating; this is for living with them.

@MainActor
final class NoteDocumentController {
    static let shared = NoteDocumentController()
    private var windows: [String: NSWindow] = [:]
    func close(id: String) {
        let window = windows.removeValue(forKey: id)
        (window as? DocumentWindow)?.autosave?.discardPendingChanges()
        window?.contentView = nil; window?.close()
    }

    func open(_ note: Note) {
        if let existing = windows[note.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = DocumentWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(MM.Document.windowSize)
        window.minSize = NSSize(width: 560, height: 420)
        window.isMovableByWindowBackground = false
        let autosave = DocumentAutosave()
        window.autosave = autosave
        window.center()
        window.contentView = NSHostingView(rootView: NoteDocumentView(note: note, autosave: autosave))
        windows[note.id] = window
        Analytics.track("note_document_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct NoteDocumentView: View {
    let note: Note
    @State private var body_: String
    @StateObject private var autosave: DocumentAutosave
    @StateObject private var editor = RichEditorSession()
    @State private var showRelated = false
    private let store: NotesStore

    init(note: Note, autosave: DocumentAutosave? = nil, store: NotesStore? = nil) {
        self.note = note
        self.store = store ?? NotesStore()
        _body_ = State(initialValue: note.body)
        _autosave = StateObject(wrappedValue: autosave ?? DocumentAutosave())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MM.Layout.spacing) {
                IconView(icon: .note, color: MM.Colors.textTertiary)
                Text("Note").foregroundStyle(MM.Colors.textSecondary)
                Text(note.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                Button { showRelated.toggle() } label: {
                    IconView(icon: .related).clickable(minSize: 28)
                }.buttonStyle(.plain).help("Related captures").accessibilityLabel("Related captures")
                Menu {
                    if FontProjectStore.exists(note.id) {
                        Button("Edit font…") { CaptureActions.perform { try FontWorkbenchController.openProject(noteID: note.id) } }
                        Button("Open font in Font Book") { if let url = FontProjectStore.asset(note.id, "font.otf") { NSWorkspace.shared.open(url) } }
                        Divider()
                    }
                    Button("Copy text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MarkdownRich.plainText(body_), forType: .string)
                    }
                    Button("Copy Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(body_, forType: .string)
                    }
                    Button("Copy file path") {
                        autosave.flush()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Brain.noteFilePath(id: note.id, createdAt: note.createdAt), forType: .string)
                    }
                } label: { Image(systemName: "ellipsis").clickable(minSize: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Note actions").accessibilityLabel("Note actions")
            }
            .font(MM.Fonts.metadata)
            .foregroundStyle(MM.Colors.textSecondary)
            .padding(.horizontal, MM.Document.margin)
            .padding(.top, MM.Layout.paddingLarge)
            .padding(.bottom, MM.Layout.spacing)
            if let meetingID = note.meetingID { NoteMeetingLink(meetingID: meetingID) }
            RichMarkdownEditor(markdown: Binding(get: { body_ }, set: { text in
                body_ = text
                autosave.submit { try store.updateDocument(note, body: text) }
            }), session: editor, showsEmptyPlaceholder: false, documentID: "note-" + note.id)
            .overlay {
                if body_.isEmpty {
                    UtilityEmptyState(icon: .note, title: "Room for a thought", message: "Start typing, or drop something in.")
                        .allowsHitTesting(false)
                }
            }
            if showRelated {
                CaptureRelatedSection(itemID: "note-" + note.id).padding(MM.Layout.padding)
            }
            DocumentFooter(session: editor, text: body_, autosave: autosave)
        }
        .background(MM.Colors.background)
        .frame(minWidth: 560, minHeight: 420)
        .onDisappear { autosave.flush() }
    }
}
