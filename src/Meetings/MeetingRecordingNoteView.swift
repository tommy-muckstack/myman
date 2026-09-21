import SwiftUI

enum MeetingRecordingTab: String, CaseIterable {
    case transcript = "Transcript"
    case summary = "Summary"
    case notes = "Notes"
    case screenshots = "Screenshots"
}

struct MeetingRecordingTabs: View {
    @Binding var selection: MeetingRecordingTab
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeetingRecordingTab.allCases, id: \.self) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.38, dampingFraction: 0.62)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .lineLimit(1)
                        .font(MM.Fonts.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selected ? MM.Colors.accent : MM.Colors.textSecondary)
                        .padding(.horizontal, MM.Layout.spacing * 0.65)
                        .padding(.vertical, MM.Layout.spacing / 2)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: MM.Layout.radiusSmall - 3)
                                    .fill(MM.Colors.accent.opacity(0.12))
                                    .matchedGeometryEffect(id: "selected-tab", in: highlight, properties: reduceMotion ? [] : .frame)
                            }
                        }
                        .clickable(minSize: 28)
                }
                .buttonStyle(RecordingTabPressStyle(reduceMotion: reduceMotion))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording details")
    }
}

private struct RecordingTabPressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct MeetingRecordingNoteView: View {
    @ObservedObject var draft: MeetingRecordingNote
    var onFocusChanged: (Bool) -> Void
    @State private var focused = false
    @State private var showsSaved = false

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
                    .opacity(draft.hasSaveError || draft.isDirty || draft.note == nil || showsSaved ? 1 : 0)
                    .accessibilityHidden(!draft.hasSaveError && !draft.isDirty && draft.note != nil && !showsSaved)
                if draft.hasSaveError {
                    Button("Retry") { draft.flush() }
                        .buttonStyle(.plain).font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.accent).clickable()
                }
            }
        }
        .task(id: draft.note?.updatedAt) {
            showsSaved = draft.note != nil
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            showsSaved = false
        }
        .onChange(of: focused) { _, focused in
            onFocusChanged(focused)
            if !focused { draft.flush() }
        }
        .onDisappear { draft.flush(); onFocusChanged(false) }
    }
}
