import AppKit
import SwiftUI

enum SaveState { case idle, pending, saved, failed }

/// Independent fields share a debounce without cancelling each other's edits.
@MainActor final class DocumentAutosave: ObservableObject {
    @Published private(set) var state: SaveState = .idle
    private var pending: [String: () throws -> Void] = [:]
    private var task: Task<Void, Never>?

    func submit(_ key: String = "body", save: @escaping () throws -> Void) {
        pending[key] = save
        state = .pending
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel(); task = nil
        guard !pending.isEmpty else { return }
        for key in pending.keys.sorted() {
            do { try pending[key]?(); pending.removeValue(forKey: key) }
            catch { state = .failed }
        }
        state = pending.isEmpty ? .saved : .failed
    }

    func discardPendingChanges() {
        task?.cancel(); task = nil
        pending.removeAll()
        state = .idle
    }
}

final class DocumentWindow: NSWindow {
    var autosave: DocumentAutosave?
    override func close() { autosave?.flush(); super.close() }
}

struct SaveIndicator: View {
    let state: SaveState
    var body: some View {
        Text(state == .pending ? "Saving…" : state == .failed ? "Not saved" : "Saved locally")
            .font(MM.Fonts.metadata)
            .foregroundStyle(state == .failed ? MM.Colors.danger : MM.Colors.textTertiary)
            .accessibilityLabel(state == .failed ? "Changes could not be saved" : state == .pending ? "Saving changes" : "Saved locally")
    }
}

struct DocumentFooter: View {
    let session: RichEditorSession
    let text: String
    @ObservedObject var autosave: DocumentAutosave
    private var words: Int { MarkdownRich.plainText(text).split(whereSeparator: \.isWhitespace).count }
    var body: some View {
        HStack(spacing: MM.Layout.spacing) {
            Menu {
                ForEach(DocumentBlock.allCases) { block in
                    Button { session.insert(block) } label: { Label(block.label, systemImage: block.symbol) }
                }
            } label: {
                Label("Insert", systemImage: "plus").font(MM.Fonts.secondary).clickable(minSize: 28)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Insert a heading, list, checklist or quote. You can also type / on a new line.")
            Text("/ to insert · select to format").font(MM.Fonts.hint).foregroundStyle(MM.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(words) \(words == 1 ? "word" : "words")").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            if autosave.state == .failed {
                Button("Retry save") { autosave.flush() }.buttonStyle(.plain).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.danger).clickable()
            } else { SaveIndicator(state: autosave.state) }
        }
        .padding(.horizontal, MM.Document.margin)
        .padding(.vertical, MM.Layout.spacing)
        .background(MM.Colors.background)
    }
}
