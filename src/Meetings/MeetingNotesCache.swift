import Foundation
import CryptoKit

/// Exact source windows only. Changed wording, speakers, privacy filtering or
/// source IDs produce a new key, so old claims cannot leak into a new draft.
actor MeetingNotesCache {
    static let shared = MeetingNotesCache()
    struct Entry: Codable {
        var facts: [MeetingFact]
        var actions: [MeetingCommitment]
        var unclear: Int
        var topics: [MeetingTopic]? = nil
    }
    private var files: [URL: [String: Entry]] = [:]

    private func key(_ source: String) -> String {
        SHA256.hash(data: Data(("meeting-notes-v2-faithful\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func value(for source: String, at url: URL?) -> Entry? {
        guard let url else { return nil }
        if files[url] == nil {
            files[url] = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))) ?? [:]
        }
        return files[url]?[key(source)]
    }

    func save(_ entry: Entry, source: String, at url: URL?) {
        guard let url else { return }
        _ = value(for: source, at: url)
        files[url]?[key(source)] = entry
        if let entries = files[url], let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func url(for meeting: Meeting) -> URL? {
        MeetingTranscriptCheckpoint.url(micPath: meeting.micAudioPath, systemPath: meeting.systemAudioPath)?
            .deletingPathExtension().appendingPathExtension("notes-cache.json")
    }
}
