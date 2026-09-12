import AppKit
import GRDB

@MainActor enum AgentNoteAssets {
    static func attach(_ args: [String: Any], database: DatabaseQueue = Database.shared, assets: DocumentAssets = .shared) throws -> [String: Any] {
        guard let id = args["id"] as? String, let item = CaptureIndex.item(id, database: database), item.kind == "note", !item.excluded else { throw AgentError("NOT_FOUND", "Expected an available note ID.") }
        guard (args["source_id"] != nil) != (args["path"] != nil) else { throw AgentError("INVALID_ARGUMENTS", "Choose source-id or path.") }
        let url: URL
        if let sourceID = args["source_id"] as? String {
            guard let source = CaptureIndex.item(sourceID, database: database), source.kind == "screenshot", !source.excluded else { throw AgentError("NOT_FOUND", "Screenshot is unavailable or excluded.") }
            url = URL(fileURLWithPath: source.sourcePath)
        } else {
            guard let path = args["path"] as? String, path.hasPrefix("/") else { throw AgentError("INVALID_ARGUMENTS", "Use an absolute image path.") }
            url = URL(fileURLWithPath: path)
        }
        let image = try AgentImages.load(url)
        let reference = try assets.importImage(data: AgentImages.png(image), documentID: item.id)
        guard let owned = assets.resolve(reference) else { throw AgentError("SAVE_FAILED", "Cannot resolve imported image.") }
        let alt = (args["alt"] as? String ?? "Screenshot").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
        let markdown = "![\(alt)](\(reference))"
        do {
            var saved: Note!
            try database.write { db in
                guard var note = try Note.fetchOne(db, key: item.sourceID), let current = try CaptureItem.fetchOne(db, key: id), !current.excluded else { throw AgentError("NOT_FOUND", "Note was deleted or hidden.") }
                if let expected = args["expected_updated_at"] as? String, expected != AgentActions.date(note.updatedAt) { throw AgentError("EDIT_CONFLICT", "The note changed; read it before attaching again.") }
                note.body += (note.body.isEmpty ? "" : "\n\n") + markdown
                guard note.body.count <= 500000 else { throw AgentError("TOO_LARGE", "The resulting note exceeds 500,000 characters.") }
                note.updatedAt = Date(); try note.update(db); saved = note
            }
            if database === Database.shared { Brain.syncNote(id: saved.id, title: saved.title, body: saved.body, createdAt: saved.createdAt, updatedAt: saved.updatedAt) }
            return ["id": item.id, "updated_at": AgentActions.date(saved.updatedAt), "markdown": markdown, "asset_reference": reference, "attachment": AgentMediaStore.imageAttachment(image, path: owned.path)]
        } catch { try? FileManager.default.removeItem(at: owned); throw error }
    }
}
