import SwiftUI
import GRDB

struct MeetingLinkedNotesView: View {
    let meetingID: String
    var database: DatabaseQueue? = nil
    @State private var notes: [Note] = []

    var body: some View {
        Group {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                    ForEach(notes) { note in
                        Button { NoteDocumentController.shared.open(note) } label: {
                            HStack(spacing: MM.Layout.spacing / 2) {
                                IconView(icon: .note, color: MM.Colors.textSecondary)
                                Text("My note: \(note.title)").lineLimit(1)
                            }
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.textPrimary)
                            .clickable()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MM.Document.margin)
                .padding(.bottom, MM.Layout.spacing)
            }
        }
        .task(id: meetingID) {
            let id = meetingID
            let observation = ValueObservation.tracking { db in
                try Note.filter(Column("meetingID") == id).fetchAll(db)
            }
            do {
                for try await value in observation.values(in: database ?? Database.shared) { notes = value }
            } catch { }
        }
    }
}

struct NoteMeetingLink: View {
    let meetingID: String
    @State private var title: String?

    var body: some View {
        Group {
            if let title {
                Button { MeetingDocumentController.shared.open(meetingID: meetingID) } label: {
                    Text("Meeting: \(title)")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(1)
                        .clickable()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MM.Document.margin)
                .padding(.bottom, MM.Layout.spacing)
            }
        }
        .task(id: meetingID) {
            let id = meetingID
            let observation = ValueObservation.tracking { db in try Meeting.fetchOne(db, key: id)?.title }
            do {
                for try await value in observation.values(in: Database.shared) { title = value }
            } catch { }
        }
    }
}
