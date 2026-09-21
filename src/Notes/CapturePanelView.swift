import SwiftUI

// The notes surface: a focused field that appears over your work.
// ⏎ saves (⇧⏎ for a newline), Esc dismisses, typing surfaces matching
// past notes beneath — capture and recall are the same gesture.
struct CapturePanelView: View {
    @ObservedObject var store: NotesStore
    @State private var draft: String
    @State private var editing: Note?
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    var onDismiss: () -> Void

    init(store: NotesStore, initialEditing: Note? = nil, initialDraft: String? = nil,
         onDismiss: @escaping () -> Void = {}) {
        self.store = store
        self.onDismiss = onDismiss
        _editing = State(initialValue: initialEditing)
        _draft = State(initialValue: initialDraft ?? initialEditing?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputField
            if saveFailed { Text("Couldn’t save. Your draft is still here; press Return to try again.").font(MM.Fonts.hint).padding(.horizontal, MM.Layout.padding) }
            if !store.results.isEmpty {
                Divider().overlay(MM.Colors.border)
                resultsList
            }
            footer
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
        .onAppear {
            store.refresh()
            focused = true
        }
    }

    private var inputField: some View {
        TextEditor(text: $draft)
            .font(MM.Fonts.bodyInput)
            .foregroundStyle(MM.Colors.textPrimary)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .frame(minHeight: draft.isEmpty && editing == nil ? 280 : 44, maxHeight: draft.isEmpty && editing == nil ? 280 : 180)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MM.Layout.padding)
            .padding(.top, MM.Layout.padding)
            .padding(.bottom, MM.Layout.spacing)
            .focused($focused)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    UtilityEmptyState(icon: .note, title: editing == nil ? "Room for a thought" : "A fresh start", message: "Give it a title. Press Return to start writing.")
                        .allowsHitTesting(false)
                }
            }
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                commit()
                return .handled
            }
            .onChange(of: draft) { _, newValue in
                guard editing == nil else { return }
                store.refresh(matching: newValue)
            }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.results) { note in
                    NoteRow(note: note, onDelete: {
                        withAnimation(MM.Motion.gentle) {
                            store.delete(note)
                            store.refresh(matching: editing == nil ? draft : "")
                        }
                    })
                    .onTapGesture {
                        onDismiss()
                        NoteDocumentController.shared.open(note)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 320)
    }

    private var footer: some View {
        HStack(spacing: MM.Layout.spacing) {
            Text(editing == nil ? "⏎ start writing" : "⏎ open note")
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            Text("⇧⏎ newline")
            Text("esc dismiss")
            Spacer()
            IconView(icon: .close, size: 12, color: MM.Colors.textTertiary)
                .clickable(minSize: 32)
                .onTapGesture { onDismiss() }
                .help("Close without saving")
            if editing != nil {
                Button("New note") { resetToCapture() }
                    .buttonStyle(.plain)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .font(MM.Fonts.hint)
            }
        }
        .font(MM.Fonts.hint)
        .foregroundStyle(MM.Colors.textTertiary)
        .padding(.horizontal, MM.Layout.padding)
        .padding(.vertical, 10)
    }

    private func commit() {
        let saved: Note
        if let note = editing {
            guard store.update(note, body: draft) else { saveFailed = true; return }
            var updated = note
            updated.body = draft
            updated.title = note.meetingID == nil ? Note.deriveTitle(from: draft) : note.title
            saved = updated
        } else {
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let note = store.save(body: draft, continueWriting: true) else { saveFailed = true; return }
            saved = note
        }
        resetToCapture()
        onDismiss()
        NoteDocumentController.shared.open(saved, focusAtEnd: true)
    }

    private func beginEditing(_ note: Note) {
        withAnimation(MM.Motion.silky) {
            editing = note
            draft = note.body
        }
        focused = true
    }

    private func resetToCapture() {
        withAnimation(MM.Motion.gentle) {
            editing = nil
            draft = ""
        }
        store.refresh()
    }
}

private struct NoteRow: View {
    let note: Note
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MM.Layout.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(MM.Fonts.body)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .lineLimit(1)
                if note.body != note.title {
                    Text(MarkdownRich.plainText(note.body).replacingOccurrences(of: "\n", with: "  "))
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(note.updatedAt.formatted(.relative(presentation: .named)))
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textTertiary)
                .opacity(hovering ? 0 : 1)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(MM.Colors.textTertiary)
                    .clickable()
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, MM.Layout.spacing)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .fill(hovering ? MM.Colors.surface : .clear)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(MM.Motion.gentle) { hovering = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
