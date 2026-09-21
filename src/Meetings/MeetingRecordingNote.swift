import Combine
import Foundation
import GRDB

/// A recording's optional personal note. Merely opening the field never
/// inserts a row. Saves update one ordinary MyMan note with a durable link.
@MainActor
final class MeetingRecordingNote: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var note: Note?
    @Published private(set) var hasSaveError = false
    @Published private(set) var isDirty = false
    private var meetingID: String?
    private var saveTask: Task<Void, Never>?
    private let database: DatabaseQueue?
    private var db: DatabaseQueue { database ?? Database.shared }

    init(database: DatabaseQueue? = nil) { self.database = database }

    func reset(meetingID: String?) {
        saveTask?.cancel()
        self.meetingID = meetingID
        note = meetingID.flatMap { id in
            try? db.read { try Note.filter(Column("meetingID") == id).fetchOne($0) }
        }
        text = note?.body ?? ""
        hasSaveError = false
        isDirty = false
    }

    func update(_ text: String) {
        guard meetingID != nil, self.text != text else { return }
        self.text = text
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let meetingID else { return true }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = note
        do {
            let saved: Note? = try db.write { db in
                guard let meeting = try Meeting.fetchOne(db, key: meetingID) else { throw CocoaError(.fileNoSuchFile) }
                if body.isEmpty {
                    if let previous { _ = try Note.deleteOne(db, key: previous.id) }
                    return nil
                }
                var updated = previous ?? Note(body: body)
                updated.body = body
                updated.title = previous?.title ?? meeting.title
                updated.updatedAt = Date()
                updated.meetingID = meetingID
                if previous != nil {
                    guard try Note.fetchOne(db, key: updated.id) != nil else { throw CocoaError(.fileNoSuchFile) }
                    try updated.update(db)
                } else {
                    try updated.insert(db)
                }
                return updated
            }
            note = saved
            isDirty = false
            hasSaveError = false
            if database == nil {
                if let saved {
                    Brain.syncNote(id: saved.id, title: saved.title, body: saved.body,
                                   createdAt: saved.createdAt, updatedAt: saved.updatedAt)
                    if previous == nil { Analytics.track("note_created", ["source": "meeting", "chars": body.count]) }
                } else if let previous {
                    Brain.deleteNote(id: previous.id, createdAt: previous.createdAt)
                }
            }
            return true
        } catch {
            hasSaveError = true
            return false
        }
    }

    /// Cancelling the take also removes its in-recorder note. On failure the
    /// caller keeps the recording/draft available so the user can retry.
    func discard() -> Bool {
        saveTask?.cancel()
        do {
            if let note {
                try db.write { _ = try Note.deleteOne($0, key: note.id) }
                if database == nil { Brain.deleteNote(id: note.id, createdAt: note.createdAt) }
            }
            reset(meetingID: nil)
            return true
        } catch {
            hasSaveError = true
            return false
        }
    }
}
