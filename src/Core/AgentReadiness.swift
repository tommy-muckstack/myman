import Foundation
import GRDB

enum AgentReadiness {
    static func item(_ id: String, stage: String, database: DatabaseQueue = Database.shared, root: URL = Brain.root) throws -> [String: Any] {
        try database.read { db in
            guard let item = try CaptureItem.fetchOne(db, key: id), !item.excluded else { throw AgentError("NOT_FOUND", "Item was deleted, excluded, or is unavailable.") }
            var ready = false
            var detail: [String: Any] = [:]
            switch stage {
            case "file":
                guard !item.sourcePath.isEmpty else { throw AgentError("UNSUPPORTED_STAGE", "This item has no source media file; use indexed or export.") }
                ready = FileManager.default.fileExists(atPath: item.sourcePath)
                detail["path"] = item.sourcePath
            case "ocr":
                guard item.kind == "screenshot" else { throw AgentError("UNSUPPORTED_STAGE", "OCR readiness requires a screenshot.") }
                let stored = try String.fetchOne(db, sql: "SELECT imageVersion FROM captureOCR WHERE itemID=?", arguments: [id])
                ready = stored != nil && stored == OCRStore.version(URL(fileURLWithPath: item.sourcePath))
                if ready { detail["text"] = item.body }
            case "indexed":
                ready = try Int.fetchOne(db, sql: "SELECT count(*) FROM capturePending WHERE id=?", arguments: [id]) == 0
            case "transcript":
                guard ["meeting", "recording", "dictation"].contains(item.kind) else { throw AgentError("UNSUPPORTED_STAGE", "This item does not have a transcript.") }
                ready = !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if ready { detail["text"] = item.body }
                else { detail["reason"] = "No transcript is available yet. A silent recording or failed processing may never produce one." }
            case "notes":
                guard item.kind == "meeting" else { throw AgentError("UNSUPPORTED_STAGE", "Meeting notes readiness requires a meeting.") }
                ready = !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if ready { detail["text"] = item.summary }
            case "export":
                let url = root.appendingPathComponent("catalog.json")
                if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 32 * 1024 * 1024,
                   let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(BrainAgentExport.Catalog.self, from: data),
                   let entry = catalog.exports.first(where: { $0.item_id == id && $0.revision == item.revision }) {
                    let path = root.appendingPathComponent(entry.path)
                    ready = FileManager.default.fileExists(atPath: path.path)
                    detail["path"] = path.path
                }
            default: throw AgentError("INVALID_ARGUMENTS", "Choose file, ocr, indexed, transcript, notes, or export.")
            }
            return ["id": id, "stage": stage, "state": ready ? "ready" : "pending", "ready": ready, "revision": item.revision].merging(detail) { _, value in value }
        }
    }
}
