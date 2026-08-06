import Foundation
import GRDB

struct Note: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    var id: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(body: String) {
        self.id = UUID().uuidString
        self.title = Note.deriveTitle(from: body)
        self.body = body
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// First non-empty line, trimmed to something list-friendly. AI titles
    /// (on-device) replace this on macOS 26+ in a later pass.
    static func deriveTitle(from body: String) -> String {
        let body = MarkdownRich.plainText(body)
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
