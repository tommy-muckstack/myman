import Foundation
import GRDB

struct VoiceProfile: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "voiceProfile"
    var id: String
    var name: String
    var embeddingJSON: String
    var updatedAt: Date
    var embedding: [Float] { (try? JSONDecoder().decode([Float].self, from: Data(embeddingJSON.utf8))) ?? [] }
}

enum VoiceProfiles {
    static func all(database: DatabaseQueue = Database.shared) throws -> [VoiceProfile] {
        try database.read { try VoiceProfile.fetchAll($0) }
    }

    /// Only explicit, named confirmations reach this store. No inferred
    /// address/response cue is allowed to enroll or change a voice profile.
    @discardableResult
    static func remember(name: String, embedding: [Float], database: DatabaseQueue = Database.shared) throws -> VoiceProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MeetingSource.genericSpeaker(name), embedding.count == 256,
              embedding.allSatisfy(\.isFinite), embedding.contains(where: { abs($0) > 0.0001 }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let json = String(decoding: try JSONEncoder().encode(embedding), as: UTF8.self)
        return try database.write { db in
            let existing = try VoiceProfile.fetchAll(db).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let profile = VoiceProfile(id: existing?.id ?? UUID().uuidString, name: name,
                                       embeddingJSON: json, updatedAt: Date())
            try profile.save(db)
            return profile
        }
    }

    static func forget(name: String, database: DatabaseQueue = Database.shared) throws {
        try database.write { db in
            for profile in try VoiceProfile.fetchAll(db) where profile.name.caseInsensitiveCompare(name) == .orderedSame {
                _ = try VoiceProfile.deleteOne(db, key: profile.id)
            }
        }
    }
}
