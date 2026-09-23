import Foundation
import GRDB

struct CaptureTheme: Identifiable, FetchableRecord {
    var id: String
    var title: String
    var description: String
    var signature: String
    var pinned: Bool
    var count: Int
    var latest: Date
    var kinds: String
    var typeCounts: String
    init(row: Row) {
        id = row["id"]; title = row["title"]; signature = row["signature"]
        description = row["description"]
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
        try database.read { try list(itemID: itemID, in: $0) }
    }

    static func list(itemID: String? = nil, in db: GRDB.Database) throws -> [CaptureTheme] {
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

    static func rename(_ id: String, title: String, expectedVersion: String? = nil, database: DatabaseQueue = Database.shared) throws {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !title.isEmpty else { return }
        try database.write { try AgentVersions.check("theme", id: id, expected: expectedVersion, db: $0); try $0.execute(sql: "UPDATE captureTheme SET title = ?, renamed = 1 WHERE id = ?", arguments: [title, id]) }
        notify()
    }
    static func pin(_ id: String, pinned: Bool, expectedVersion: String? = nil, database: DatabaseQueue = Database.shared) throws {
        try database.write { try AgentVersions.check("theme", id: id, expected: expectedVersion, db: $0); try $0.execute(sql: "UPDATE captureTheme SET pinned = ? WHERE id = ?", arguments: [pinned, id]) }; notify()
    }
    static func dismiss(_ id: String, expectedVersion: String? = nil, database: DatabaseQueue = Database.shared) throws {
        try database.write { db in
            try AgentVersions.check("theme", id: id, expected: expectedVersion, db: db)
            try db.execute(sql: "UPDATE captureTheme SET dismissed = 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }
    static func assign(_ itemID: String, to themeID: String, remove: Bool = false, expectedVersion: String? = nil, database: DatabaseQueue = Database.shared) throws {
        try database.write { db in
            try AgentVersions.check("theme", id: themeID, expected: expectedVersion, db: db)
            try db.execute(sql: """
                INSERT INTO captureThemeMember(themeID,itemID,manual,blocked) SELECT ?,id,1,? FROM captureItem WHERE id = ? AND excluded = 0
                ON CONFLICT(themeID,itemID) DO UPDATE SET manual = 1, blocked = excluded.blocked
                """, arguments: [themeID, remove, itemID])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }
    static func merge(_ source: String, into target: String, expectedVersion: String? = nil, targetVersion: String? = nil, database: DatabaseQueue = Database.shared) throws {
        guard source != target else { return }
        try database.write { db in
            try AgentVersions.check("theme", id: source, expected: expectedVersion, db: db)
            try AgentVersions.check("theme", id: target, expected: targetVersion, db: db)
            try db.execute(sql: """
                INSERT INTO captureThemeMember(themeID,itemID,manual,blocked)
                SELECT ?,itemID,1,blocked FROM captureThemeMember WHERE themeID = ?
                ON CONFLICT(themeID,itemID) DO UPDATE SET manual=1,blocked=min(blocked,excluded.blocked)
                """, arguments: [target, source])
            try db.execute(sql: "UPDATE captureTheme SET dismissed = 1 WHERE id = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM captureRelation WHERE kind = 'same_theme'")
        }; notify()
    }

    /// Apply a complete conceptual pass using stable IDs and existing correction
    /// rows. Inference never replaces explicit membership or a user's title.
    static func infer(in db: GRDB.Database, items: [CaptureItem], enabled: Bool,
                      prepared: [ConceptThemes.Proposal]? = nil,
                      retireUnmatched: Bool = true, preserveConcepts: Bool = false) throws {
        guard enabled else { return }
        var proposals: [ConceptThemes.Proposal] = []
        for proposal in prepared ?? ConceptThemes.fallback(items) {
            let words = CaptureText.words(proposal.title)
            if let index = proposals.firstIndex(where: { CaptureText.words($0.title) == words }) {
                proposals[index].members.formUnion(proposal.members)
                proposals[index].digest = "semantic:" + ConceptThemes.digest([proposals[index].digest, proposal.digest].sorted())
            } else { proposals.append(proposal) }
        }
        let allowed = Set(items.filter { !$0.excluded }.map(\.id))
        let existing = try Row.fetchAll(db, sql: "SELECT * FROM captureTheme ORDER BY id")
        var memberships: [String: Set<String>] = [:]
        var corrected = Set<String>()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM captureThemeMember") {
            let id: String = row["themeID"]
            memberships[id, default: []].insert(row["itemID"])
            if row["manual"] as Bool { corrected.insert(id) }
        }
        func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
            Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
        }
        var matched = Set<String>(), used: [Set<String>] = []
        var signatures = Set(existing.map { $0["signature"] as String })
        for proposal in proposals.prefix(12) {
            let members = proposal.members.intersection(allowed)
            guard members.count >= 3, !used.contains(where: { overlap($0, members) > 0.7 }) else { continue }
            let signature = "concept:" + CaptureText.words(proposal.title).joined(separator: " ")
            // A dismissal applies to that concept, not every smaller subject
            // which happened to share a broad legacy phrase or person's name.
            if existing.contains(where: { row in
                (row["dismissed"] as Bool) && ((row["signature"] as String) == signature || CaptureText.words(row["title"] as String) == CaptureText.words(proposal.title) || overlap(memberships[row["id"]] ?? [], members) >= 0.6)
            }) { continue }
            let match = existing.filter { !(($0["dismissed"] as Bool)) && !matched.contains($0["id"]) }.compactMap { row -> (Row, Double)? in
                let similarity = overlap(memberships[row["id"]] ?? [], members)
                let sameTitle = CaptureText.words(row["title"] as String) == CaptureText.words(proposal.title)
                let same = (row["signature"] as String) == signature || (row["conceptDigest"] as String) == proposal.digest || sameTitle
                return same || similarity >= 0.5 ? (row, same ? 2 : similarity) : nil
            }.max { $0.1 < $1.1 }?.0
            let id: String = match?["id"] ?? UUID().uuidString
            if let match {
                let keepTitle = (match["renamed"] as Bool) || (match["pinned"] as Bool)
                try db.execute(sql: "UPDATE captureTheme SET title = ?, description = ?, conceptDigest = ? WHERE id = ?",
                               arguments: [keepTitle ? match["title"] as String : proposal.title, proposal.description, proposal.digest, id])
                try db.execute(sql: "DELETE FROM captureThemeMember WHERE themeID = ? AND manual = 0", arguments: [id])
            } else {
                // Signature is a creation identity; matched themes keep it so
                // renaming and inference refinements don't break references.
                guard signatures.insert(signature).inserted else { continue }
                try db.execute(sql: "INSERT INTO captureTheme(id,title,signature,description,conceptDigest) VALUES(?,?,?,?,?)",
                               arguments: [id, proposal.title, signature, proposal.description, proposal.digest])
            }
            for member in members {
                try db.execute(sql: "INSERT OR IGNORE INTO captureThemeMember(themeID,itemID) VALUES (?,?)", arguments: [id, member])
            }
            matched.insert(id); used.append(members)
        }
        if retireUnmatched {
            for row in existing {
                let id: String = row["id"]
                guard !matched.contains(id), !(row["dismissed"] as Bool), !(row["renamed"] as Bool),
                      !(row["pinned"] as Bool), !corrected.contains(id),
                      !preserveConcepts || !(row["conceptDigest"] as String).hasPrefix("semantic:") else { continue }
                try db.execute(sql: "DELETE FROM captureTheme WHERE id = ?", arguments: [id])
            }
        }
    }

    static func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: .captureLibraryChanged, object: nil) } }
}

extension Notification.Name { static let captureLibraryChanged = Notification.Name("man.captureLibraryChanged") }
