import SwiftUI

struct MeetingRecordingNoteView: View {
    @ObservedObject var draft: MeetingRecordingNote
    var onFocusChanged: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            HStack {
                Text("Linked to this meeting")
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textSecondary)
                Spacer()
                if draft.note != nil {
                    Button("Open note") {
                        if draft.flush(), let note = draft.note { NoteDocumentController.shared.open(note) }
                    }
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.accent)
                    .buttonStyle(.plain)
                    .clickable()
                }
            }
            TextEditor(text: Binding(get: { draft.text }, set: { draft.update($0) }))
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(MM.Layout.spacing / 2)
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Add a thought, question, or follow-up…")
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.textTertiary)
                            .padding(MM.Layout.spacing)
                            .allowsHitTesting(false)
                    }
                }
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                    .strokeBorder(focused ? MM.Colors.accent : MM.Colors.border, lineWidth: 1))
                .accessibilityLabel("Your note for this meeting")
            HStack {
                Text(draft.hasSaveError ? "Couldn’t save your note." : draft.isDirty ? "Saving…" : draft.note == nil ? "A note is created when you write something." : "Saved to MyMan notes")
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(draft.hasSaveError ? MM.Colors.danger : MM.Colors.textTertiary)
                if draft.hasSaveError {
                    Button("Retry") { draft.flush() }
                        .buttonStyle(.plain).font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.accent).clickable()
                }
            }
        }
        .onChange(of: focused) { _, focused in
            onFocusChanged(focused)
            if !focused { draft.flush() }
        }
        .onDisappear { draft.flush(); onFocusChanged(false) }
    }
}
