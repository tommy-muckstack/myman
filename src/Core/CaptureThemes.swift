import Foundation
import GRDB

struct CaptureTheme: Identifiable, FetchableRecord {
    var id: String
    var title: String
    var signature: String
    var pinned: Bool
    var count: Int
    var latest: Date
    var kinds: String
    var typeCounts: String
    init(row: Row) {
        id = row["id"]; title = row["title"]; signature = row["signature"]
        pinned = row["pinned"]; count = row["itemCount"]; latest = row["latest"]; kinds = row["kinds"]
        typeCounts = ["meeting", "screenshot", "dictation", "recording", "note"].compactMap { kind in
            let count: Int = row[kind + "Count"]
            return count > 0 ? "\(count) \(kind)\(count == 1 ? "" : "s")" : nil
        }.joined(separator: " · ")
    }
}

struct CaptureRelationship: Identifiable {
    var item: CaptureItem
    var score: Double
    var kind: String
    var reason: String
    var id: String { item.id }
}

enum CaptureSignals {
    static let stopWords = Set("a an the and or but to of for from with at by in on this that these those is are was were be been it its my your our we i you they he she me us as do did does will would can could should have has had not no yes into about just more very some all new next last today yesterday tomorrow monday tuesday wednesday thursday friday saturday sunday meeting meetings notes note screenshot recording transcript summary speaker unknown untitled file edit view window help copy save open close search http https www com org net app page screen click start stop okay like want need think know going really also get got one two now then there here let lets thanks thank please see said says discussion action items minutes seconds time date".split(separator: " ").map(String.init))

    static func terms(_ item: CaptureItem) -> Set<String> {
        Set(CaptureText.words(item.title + "\n" + String(item.body.prefix(10000)) + "\n" + String(item.summary.prefix(4000)))
            .filter { $0.count > 2 && !stopWords.contains($0) && $0.rangeOfCharacter(from: .letters) != nil })
    }

    static func domains(_ text: String) -> Set<String> {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let source = String(text.prefix(16000))
        return Set(detector.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { result in
            guard let host = result.url?.host?.lowercased(), !["google.com", "zoom.us", "teams.microsoft.com"].contains(host) else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        })
    }

    /// Repeated phrases, not a cluster per capture. Restrict seeds to titles and
    /// sentence/line-local phrases so unrelated transcript words don't combine.
    static func seeds(_ item: CaptureItem) -> [String: String] {
        var result: [String: String] = [:]
        let titleWords = CaptureText.words(item.title)
        if (2...7).contains(titleWords.count), titleWords.filter({ !stopWords.contains($0) }).count >= 2,
           !item.rawTitle.isEmpty || !item.userTitle.isEmpty {
            result[titleWords.joined(separator: " ")] = item.title
        }
        let source = item.title + "\n" + String(item.body.prefix(6000))
        for line in source.components(separatedBy: .newlines).prefix(80) {
            let words = line.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard words.count > 1 else { continue }
            for length in 2...min(3, words.count) {
                for i in 0...(words.count - length) {
                    let phrase = Array(words[i..<(i + length)])
                    let normalized = phrase.map { $0.lowercased() }
                    guard normalized.allSatisfy({ $0.count > 2 && $0.rangeOfCharacter(from: .letters) != nil }),
                          !stopWords.contains(normalized[0]), !stopWords.contains(normalized[length - 1]) else { continue }
                    // A connecting utility word can be meaningful inside a
                    // topic name, e.g. “Man search redesign”.
                    result[normalized.joined(separator: " ")] = phrase.joined(separator: " ")
                }
            }
        }
        for domain in domains(source) { result["domain:" + domain] = domain }
        return result
    }
}

enum RelatedItems {
    static func score(_ source: CaptureItem, _ target: CaptureItem, sharedTheme: Bool = false, sharedTerms: Set<String>? = nil, sharedDomains: Set<String>? = nil) -> (Double, String, String)? {
        guard source.id != target.id, !source.excluded, !target.excluded else { return nil }
        if sharedTheme { return (0.95, "same_theme", "Same theme") }
        let shared = sharedTerms ?? CaptureSignals.terms(source).intersection(CaptureSignals.terms(target))
        let domains = sharedDomains ?? CaptureSignals.domains(source.text).intersection(CaptureSignals.domains(target.text))
        if let domain = domains.sorted().first { return (0.85, "shared_domain", domain) }
        if shared.count >= 2 {
            return (min(0.9, 0.55 + Double(shared.count) * 0.04), "shared_entities", shared.sorted().prefix(3).joined(separator: ", "))
        }
        let interval = abs(source.capturedAt.timeIntervalSince(target.capturedAt))
        if interval <= 15 * 60 { return (0.3 + 0.15 * (1 - interval / 900), "temporal_proximity", "Captured nearby") }
        return nil
    }

    static func items(for id: String, limit: Int = 8, database: DatabaseQueue = Database.shared) throws -> [CaptureRelationship] {
        try database.read { db in
            guard let source = try CaptureItem.fetchOne(db, key: id), !source.excluded else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, max(r.score) AS relatedScore, r.kind AS relationshipKind, r.reason AS relationshipReason
                FROM (
                  SELECT targetID,score,kind,reason FROM captureRelation WHERE sourceID = ?
                  UNION ALL
                  SELECT b.itemID,0.95,'same_theme',t.title FROM captureThemeMember a
                  JOIN captureThemeMember b ON b.themeID = a.themeID AND b.itemID != a.itemID
                  JOIN captureTheme t ON t.id = a.themeID
                  WHERE a.itemID = ? AND a.blocked = 0 AND b.blocked = 0 AND t.dismissed = 0
                ) r JOIN captureItem c ON c.id = r.targetID
                WHERE c.excluded = 0 GROUP BY c.id
                ORDER BY relatedScore DESC, c.capturedAt DESC LIMIT ?
                """, arguments: [id, id, limit])
            var results = try rows.map { row in CaptureRelationship(item: try CaptureItem(row: row), score: row["relatedScore"], kind: row["relationshipKind"], reason: row["relationshipReason"]) }
            // Nearby captures are available immediately, even while enrichment
            // is pending. Use the same scoring abstraction as persisted links.
            let nearby = try CaptureItem.fetchAll(db, sql: "SELECT * FROM captureItem WHERE excluded = 0 AND capturedAt BETWEEN ? AND ? AND id != ? ORDER BY capturedAt DESC LIMIT 30", arguments: [source.capturedAt.addingTimeInterval(-900), source.capturedAt.addingTimeInterval(900), id])
            let existing = Set(results.map(\.id))
            for item in nearby where !existing.contains(item.id) {
                if let (score, kind, reason) = score(source, item) { results.append(CaptureRelationship(item: item, score: score, kind: kind, reason: reason)) }
            }
            return Array(results.sorted { $0.score > $1.score }.prefix(limit))
        }
    }
}

enum ThemeStore {
    static func list(itemID: String? = nil, database: DatabaseQueue = Database.shared) throws -> [CaptureTheme] {
        try database.read { db in
            let clause = itemID == nil ? "" : "AND t.id IN (SELECT themeID FROM captureThemeMember WHERE itemID = ? AND blocked = 0)"
            return try CaptureTheme.fetchAll(db, sql: """
                SELECT t.*, count(c.id) AS itemCount, max(c.capturedAt) AS latest, group_concat(DISTINCT c.kind) AS kinds,
                  sum(c.kind = 'meeting') AS meetingCount, sum(c.kind = 'screenshot') AS screenshotCount,
                  sum(c.kind = 'dictation') AS dictationCount, sum(c.kind = 'recording') AS recordingCount, sum(c.kind = 'note') AS noteCount
                FROM captureTheme t JOIN captureThemeMember m ON m.themeID = t.id
                JOIN captureItem c ON c.id = m.itemID
                WHERE t.dismissed = 0 AND m.blocked = 0 AND c.excluded = 0 \(clause)
                GROUP BY t.id ORDER BY t.pinned DESC, latest DESC
                """, arguments: itemID.map { [$0] } ?? [])
        }
    }

    static func rename(_ id: String, title: String, database: DatabaseQueue = Database.shared) throws {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !title.isEmpty else { return }
        try database.write { try $0.execute(sql: "UPDATE captureTheme SET title = ?, renamed = 1 WHERE id = ?", arguments: [title, id]) }
        notify()
    }
    static func pin(_ id: String, pinned: Bool, database: DatabaseQueue = Database.shared) throws {
        try database.write { try $0.execute(sql: "UPDATE captureTheme SET pinned = ? WHERE id = ?", arguments: [pinned, id]) }; notify()
    }
    static func dismiss(_ id: String, database: DatabaseQueue = Database.shared) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE captureTheme SET dismissed = 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }
    static func assign(_ itemID: String, to themeID: String, remove: Bool = false, database: DatabaseQueue = Database.shared) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO captureThemeMember(themeID,itemID,manual,blocked) SELECT ?,id,1,? FROM captureItem WHERE id = ? AND excluded = 0
                ON CONFLICT(themeID,itemID) DO UPDATE SET manual = 1, blocked = excluded.blocked
                """, arguments: [themeID, remove, itemID])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }
    static func merge(_ source: String, into target: String, database: DatabaseQueue = Database.shared) throws {
        guard source != target else { return }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO captureThemeMember(themeID,itemID,manual,blocked)
                SELECT ?,itemID,1,blocked FROM captureThemeMember WHERE themeID = ?
                ON CONFLICT(themeID,itemID) DO UPDATE SET manual=1,blocked=min(blocked,excluded.blocked)
                """, arguments: [target, source])
            try db.execute(sql: "UPDATE captureTheme SET dismissed = 1 WHERE id = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }

    typealias Candidates = [String: (String, Set<String>, Int)]
    static func candidates(for items: [CaptureItem]) -> Candidates {
        var candidates: Candidates = [:]
        for item in items where !item.excluded {
            let title = CaptureText.words(item.title).joined(separator: " ")
            let seeds = CaptureSignals.seeds(item)
            for (signature, title) in seeds {
                if candidates[signature] == nil { candidates[signature] = (title, [], 0) }
                candidates[signature]?.1.insert(item.id)
                candidates[signature]?.2 += 1
            }
            for signature in seeds.keys where title.contains(signature) {
                candidates[signature]?.2 += 4
            }
        }
        return candidates
    }
    static func infer(in db: GRDB.Database, items: [CaptureItem], enabled: Bool, prepared: Candidates? = nil) throws {
        guard enabled else { return }
        let items = items.filter { !$0.excluded }
        let candidates = prepared ?? self.candidates(for: items)
        let existing = try Row.fetchAll(db, sql: "SELECT * FROM captureTheme")
        let knownSignatures = Set(existing.map { $0["signature"] as String })
        var used: [Set<String>] = []
        // Existing clusters retain stable identity and user names. Only inferred
        // memberships are refreshed; blocked/manual corrections remain intact.
        for row in existing {
            let id: String = row["id"], signature: String = row["signature"], dismissed: Bool = row["dismissed"]
            if dismissed {
                used.append(Set(try String.fetchAll(db, sql: "SELECT itemID FROM captureThemeMember WHERE themeID = ?", arguments: [id])))
                continue
            }
            let candidateMembers = candidates[signature]?.1 ?? []
            let members = candidateMembers.count >= 3 ? candidateMembers : []
            used.append(members)
            try db.execute(sql: "DELETE FROM captureThemeMember WHERE themeID = ? AND manual = 0", arguments: [id])
            for itemID in members { try db.execute(sql: "INSERT OR IGNORE INTO captureThemeMember(themeID,itemID) VALUES (?,?)", arguments: [id, itemID]) }
        }
        var created = 0
        for (signature, candidate) in candidates.sorted(by: {
            if $0.value.1.count != $1.value.1.count { return $0.value.1.count > $1.value.1.count }
            if $0.value.2 != $1.value.2 { return $0.value.2 > $1.value.2 }
            if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
            return $0.key < $1.key
        }) {
            guard candidate.1.count >= 3, !knownSignatures.contains(signature), created < 12 else { continue }
            // Skip near-duplicate clusters and very broad terms spanning most
            // of a larger library. Prefer a few coherent themes to microtopics.
            if items.count > 12 && Double(candidate.1.count) / Double(items.count) > 0.65 { continue }
            if used.contains(where: { Double($0.intersection(candidate.1).count) / Double(max(1, min($0.count, candidate.1.count))) > 0.7 }) { continue }
            let id = UUID().uuidString
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES (?,?,?)", arguments: [id, candidate.0, signature])
            for itemID in candidate.1 { try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES (?,?)", arguments: [id, itemID]) }
            used.append(candidate.1); created += 1
        }
        try db.execute(sql: "DELETE FROM captureTheme WHERE dismissed = 0 AND renamed = 0 AND pinned = 0 AND id NOT IN (SELECT themeID FROM captureThemeMember)")
    }

    static func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: .captureLibraryChanged, object: nil) } }
}

extension Notification.Name { static let captureLibraryChanged = Notification.Name("man.captureLibraryChanged") }
