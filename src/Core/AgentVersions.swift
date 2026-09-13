import Foundation
import GRDB
import CryptoKit

enum AgentVersions {
    static func version(_ kind: String, id: String, db: GRDB.Database) throws -> String {
        let table: String
        switch kind { case "item": table = "captureItem"; case "task": table = "task"; case "theme": table = "captureTheme"; default: throw AgentError("INVALID_ARGUMENTS", "Choose item, task, or theme.") }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id=?", arguments: [id]) else { throw AgentError("NOT_FOUND", "Resource is unavailable.") }
        if kind == "item", row["excluded"] as Bool { throw AgentError("NOT_FOUND", "Item is excluded.") }
        func values(_ row: Row) -> [[String]] { row.map { [$0.0, String(reflecting: $0.1.storage)] } }
        var rows = [values(row)]
        if kind == "theme" { rows += try Row.fetchAll(db, sql: "SELECT * FROM captureThemeMember WHERE themeID=? ORDER BY itemID", arguments: [id]).map(values) }
        let data = try JSONSerialization.data(withJSONObject: rows)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func check(_ kind: String, id: String, expected: String?, db: GRDB.Database) throws {
        if let expected, try version(kind, id: id, db: db) != expected { throw AgentError("EDIT_CONFLICT", "Resource changed; read it again before proposing another edit.") }
    }
    static func read(_ args: [String: Any]) throws -> [String: Any] {
        let kind = args["kind"] as! String, id = args["id"] as! String
        return ["kind": kind, "id": id, "version": try Database.shared.read { try version(kind, id: id, db: $0) }]
    }
    @MainActor static func validate(_ action: String, args: [String: Any], named: Bool) throws {
        if ["note.append", "note.attach", "note.update"].contains(action), named, args["expected_updated_at"] == nil { throw AgentError("REVISION_REQUIRED", "Read the note and supply expected_updated_at.") }
        if ["item.rename", "item.pin", "item.exclude", "item.delete"].contains(action) {
            guard let id = args["id"] as? String, let item = CaptureIndex.item(id) else { throw AgentError("NOT_FOUND", "Item is unavailable.") }
            if named && args["expected_revision"] == nil { throw AgentError("REVISION_REQUIRED", "Read the item and supply expected_revision.") }
            if let revision = args["expected_revision"] as? Int, revision != item.revision { throw AgentError("EDIT_CONFLICT", "Item changed; read it again.") }
        }
        if action.hasPrefix("theme.") || ["task.update", "task.delete"].contains(action) {
            if named && args["expected_version"] == nil { throw AgentError("REVISION_REQUIRED", "Use resource.version and supply expected_version.") }
            if named && action == "theme.merge" && args["target_version"] == nil { throw AgentError("REVISION_REQUIRED", "Also provide the target theme version.") }
        }
    }
}
