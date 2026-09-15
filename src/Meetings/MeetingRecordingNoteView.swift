import SwiftUI

struct MeetingRecordingNoteView: View {
    @ObservedObject var draft: MeetingRecordingNote
    var onFocusChanged: (Bool) -> Void
    @State private var focused = false

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
            // The same editor as a full note: "- " and "* " become bullets,
            // Tab nests them, ⌘B/⌘I and the slash menu all work here.
            RichMarkdownEditor(markdown: Binding(get: { draft.text }, set: { draft.update($0) }),
                               firstLineIsTitle: false,
                               placeholder: "Add a thought, question, or follow-up…",
                               documentID: draft.note.map { "note-" + $0.id } ?? "meeting-note-draft",
                               compact: true,
                               onFocusChanged: { focused = $0 })
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
