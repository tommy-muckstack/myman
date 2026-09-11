import Foundation
import GRDB

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var results: [Note] = []

    private let db = Database.shared

    func refresh(matching query: String = "") {
        let notes: [Note] = (try? db.read { db in
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.isEmpty {
                return try Note
                    .order(Column("updatedAt").desc)
                    .limit(30)
                    .fetchAll(db)
            }
            // Substring match first (instant, forgiving), FTS refines beneath.
            let like = try Note
                .filter(Column("body").like("%\(q)%") || Column("title").like("%\(q)%"))
                .order(Column("updatedAt").desc)
                .limit(20)
                .fetchAll(db)
            let fts = try Note.fetchAll(db, sql: """
                SELECT note.* FROM note
                JOIN note_fts ON note_fts.rowid = note.rowid
                WHERE note_fts MATCH ?
                ORDER BY rank LIMIT 20
                """, arguments: [FTS5Pattern(matchingAllPrefixesIn: q)])
            var seen = Set(like.map(\.id))
            return like + fts.filter { seen.insert($0.id).inserted }
        }) ?? []
        results = notes
    }

    @discardableResult
    func save(body: String, source: String = "quick_capture") -> Note? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(body: trimmed)
        try? db.write { try note.insert($0) }
        Analytics.track("note_created", ["source": source, "chars": trimmed.count])
        Brain.syncNote(id: note.id, title: note.title, body: note.body,
                       createdAt: note.createdAt, updatedAt: note.updatedAt)
        // Typed notes carry ground-truth spellings — teach the dictation
        // vocabulary. (Dictation-sourced notes are skipped: ASR guesses.)
        if source != "dictation" {
            DictationCleanup.learn(from: trimmed)
        }
        TaskExtractor.run(text: trimmed, source: .note)
        return note
    }

    func update(_ note: Note, body: String) {
        var updated = note
        updated.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = Note.deriveTitle(from: updated.body)
        updated.updatedAt = Date()
        try? db.write { try updated.update($0) }
        Analytics.track("note_updated", ["chars": updated.body.count])
        Brain.syncNote(id: updated.id, title: updated.title, body: updated.body,
                       createdAt: updated.createdAt, updatedAt: updated.updatedAt)
    }

    func delete(_ note: Note) {
        if let item = CaptureIndex.item("note-" + note.id) { CaptureActions.perform { try CaptureLifecycle.delete(item) } }
    }
}
