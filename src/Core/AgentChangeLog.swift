import Foundation

/// Append-only list of what agents can pick up: new captures, finished doc
/// images and anything else marked ready. Each entry has a sequence number, and
/// changes.since returns entries after a cursor, so an agent can poll without
/// rereading folders. Entries carry ids and paths, never image bytes or text.
enum AgentChangeLog {
    struct Entry: Equatable {
        let seq: Int
        let at: String
        let kind: String
        let id: String
        let readyFor: String?
        let paths: [String: String]

        var json: [String: Any] {
            var object: [String: Any] = ["cursor": String(seq), "at": at, "kind": kind, "id": id, "paths": paths]
            object["ready_for"] = readyFor ?? NSNull()
            return object
        }
    }
    static let maximumEntries = 1000
    static let defaultLimit = 50
    static let maximumLimit = 200

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MyMan", isDirectory: true).appendingPathComponent("agent-changes.jsonl")
    }

    /// Adds an entry and returns it. Old entries beyond maximumEntries are dropped; sequence numbers keep counting.
    @discardableResult
    static func append(kind: String, id: String, readyFor: String? = nil, paths: [String: String] = [:], at: String, url: URL = defaultURL) throws -> Entry {
        var entries = try load(url)
        let seq = (entries.last?.seq ?? 0) + 1
        let entry = Entry(seq: seq, at: at, kind: kind, id: id, readyFor: readyFor, paths: paths)
        entries.append(entry)
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
        try write(entries, url)
        return entry
    }

    /// Entries with a sequence number after the cursor, oldest first, and the cursor to ask with next time.
    static func since(cursor: Int, limit: Int = defaultLimit, url: URL = defaultURL) throws -> (cursor: Int, items: [Entry]) {
        let entries = try load(url)
        let capped = min(max(limit, 1), maximumLimit)
        let items = Array(entries.filter { $0.seq > cursor }.prefix(capped))
        return (items.last?.seq ?? cursor, items)
    }

    static func load(_ url: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> Entry? in
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seq = object["seq"] as? Int, let at = object["at"] as? String, let kind = object["kind"] as? String, let id = object["id"] as? String else { return nil }
            return Entry(seq: seq, at: at, kind: kind, id: id, readyFor: object["ready_for"] as? String, paths: object["paths"] as? [String: String] ?? [:])
        }
    }

    private static func write(_ entries: [Entry], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try entries.map { entry -> String in
            let object: [String: Any] = ["seq": entry.seq, "at": entry.at, "kind": entry.kind, "id": entry.id, "ready_for": entry.readyFor ?? NSNull(), "paths": entry.paths]
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
