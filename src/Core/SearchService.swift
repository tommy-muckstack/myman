import Foundation
import GRDB
import NaturalLanguage

// Universal search, Scrap-style: instant keyword results pinned on top,
// on-device semantic results layered underneath, deduped, degrading silently
// when embeddings aren't available. Sources: notes, screenshot OCR (the
// Snabbit indexability idea), meeting transcripts.

struct DictationRecord: Identifiable {
    let id: String
    let text: String
    let createdAt: Date
}

enum SearchHit: Identifiable {
    case note(Note)
    case screenshot(Screenshot)
    case meeting(Meeting)
    case dictation(DictationRecord)
    case recording(ScreenRecording)

    var id: String {
        switch self {
        case .note(let n): return "note-\(n.id)"
        case .screenshot(let s): return "shot-\(s.id)"
        case .meeting(let m): return "meeting-\(m.id)"
        case .dictation(let d): return "dictation-\(d.id)"
        case .recording(let r): return "recording-\(r.id)"
        }
    }

    /// User-facing source label for the result row badge.
    var kindLabel: String {
        switch self {
        case .note: return "note"
        case .screenshot: return "screenshot"
        case .meeting: return "meeting"
        case .dictation: return "dictation"
        case .recording: return "recording"
        }
    }

    var date: Date {
        switch self {
        case .note(let n): return n.updatedAt
        case .screenshot(let s): return s.createdAt
        case .meeting(let m): return m.startedAt
        case .dictation(let d): return d.createdAt
        case .recording(let r): return r.createdAt
        }
    }
}

enum SearchService {

    // MARK: Embeddings (NLEmbedding — free, local, good-enough)

    private static let embedder = NLEmbedding.sentenceEmbedding(for: .english)

    static func embedding(for text: String) -> Data? {
        let trimmed = String(text.prefix(1000))
        guard !trimmed.isEmpty,
              let vector = embedder?.vector(for: trimmed.lowercased()) else { return nil }
        let floats = vector.map(Float.init)
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decoded-vector cache: blobs decode once, not on every keystroke.
    private static let cacheLock = NSLock()
    private static var vectorCache: [String: [Float]] = [:]

    static func decodedVector(id: String, blob: Data) -> [Float] {
        let key = "\(id)-\(blob.count)-\(blob.prefix(8).hashValue)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = vectorCache[key] { return cached }
        if vectorCache.count > 2000 { vectorCache.removeAll() }
        let vector: [Float] = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        vectorCache[key] = vector
        return vector
    }

    static func cosineSimilarity(_ a: Data, _ b: Data) -> Float {
        let va: [Float] = a.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let vb: [Float] = b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return cosine(va, vb)
    }

    static func cosine(_ va: [Float], _ vb: [Float]) -> Float {
        guard va.count == vb.count, !va.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<va.count {
            dot += va[i] * vb[i]
            magA += va[i] * va[i]
            magB += vb[i] * vb[i]
        }
        let denominator = sqrt(magA) * sqrt(magB)
        return denominator > 0 ? dot / denominator : 0
    }

    // MARK: Recents (the hover-a-tile complement to search)

    /// Most recent items of one kind, newest first.
    static func recent(kind: String, limit: Int = 5) -> [SearchHit] {
        (try? Database.shared.read { db -> [SearchHit] in
            switch kind {
            case "screenshot":
                return try Screenshot.order(Column("createdAt").desc)
                    .limit(limit).fetchAll(db).map(SearchHit.screenshot)
            case "note":
                return try Note.order(Column("updatedAt").desc)
                    .limit(limit).fetchAll(db).map(SearchHit.note)
            case "meeting":
                return try Meeting.filter(Column("transcript") != "")
                    .order(Column("startedAt").desc)
                    .limit(limit).fetchAll(db).map(SearchHit.meeting)
            case "voice":
                return try Row.fetchAll(db, sql:
                    "SELECT id, text, createdAt FROM dictation ORDER BY createdAt DESC LIMIT ?",
                    arguments: [limit]).map { row in
                        .dictation(DictationRecord(
                            id: row["id"], text: row["text"], createdAt: row["createdAt"]))
                    }
            case "record":
                return try ScreenRecording.order(Column("createdAt").desc)
                    .limit(limit).fetchAll(db)
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map(SearchHit.recording)
            default:
                return []
            }
        }) ?? []
    }

    // MARK: Click learning (Mozilla-frecency-style)

    /// Record that the user opened `hit` after typing `query`. Feeds ranking:
    /// items you actually open — especially for similar queries — float up.
    static func recordClick(query: String, hit: SearchHit, rank: Int = -1, resultCount: Int = -1) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        Analytics.track("search_result_opened", [
            "kind": hit.kindLabel, "query_length": q.count,
            "rank": rank, "result_count": resultCount,
        ])
        try? Database.shared.write { db in
            try db.execute(
                sql: "INSERT INTO searchClick (query, hitID, kind, clickedAt) VALUES (?, ?, ?, ?)",
                arguments: [q, hit.id, hit.kindLabel, Date()]
            )
            // Keep the log bounded — old clicks decay to irrelevance anyway.
            try db.execute(sql: """
                DELETE FROM searchClick WHERE rowid NOT IN
                (SELECT rowid FROM searchClick ORDER BY clickedAt DESC LIMIT 2000)
                """)
        }
    }

    private struct ClickStats {
        /// hitID → [(query, age in days)]
        var perHit: [String: [(query: String, ageDays: Double)]] = [:]
        /// kind → share of all clicks (0...1)
        var kindShare: [String: Double] = [:]
    }

    private static func loadClickStats() -> ClickStats {
        var stats = ClickStats()
        guard let rows = try? Database.shared.read({ db in
            try Row.fetchAll(db, sql: "SELECT query, hitID, kind, clickedAt FROM searchClick")
        }) else { return stats }
        var kindCounts: [String: Double] = [:]
        for row in rows {
            let hitID: String = row["hitID"]
            let clickedAt: Date = row["clickedAt"]
            let age = max(0, -clickedAt.timeIntervalSinceNow / 86_400)
            stats.perHit[hitID, default: []].append((row["query"], age))
            kindCounts[row["kind"], default: 0] += 1
        }
        let total = kindCounts.values.reduce(0, +)
        if total > 0 {
            stats.kindShare = kindCounts.mapValues { $0 / total }
        }
        return stats
    }

    /// Learned boost: each past click decays with a ~14-day half-life; clicks
    /// whose query resembles the current one count ~4× more. Type prior adds
    /// a small nudge toward the kinds this user actually opens.
    private static func clickBoost(hitID: String, kind: String,
                                   query: String, stats: ClickStats) -> Float {
        var boost = 0.0
        for click in stats.perHit[hitID] ?? [] {
            let decay = pow(0.5, click.ageDays / 14)
            let related = !click.query.isEmpty
                && (query.hasPrefix(click.query) || click.query.hasPrefix(query))
            boost += decay * (related ? 0.20 : 0.05)
        }
        boost = min(boost, 0.5)
        boost += 0.05 * (stats.kindShare[kind] ?? 0)
        return Float(boost)
    }

    // MARK: Query

    /// Ranked results: keyword matches score highest (title beats body,
    /// recency breaks ties), semantic hits fill in beneath by cosine
    /// similarity. Everything local, degrades silently.
    static func search(_ query: String, limit: Int = 8) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        struct Ranked { let hit: SearchHit; let score: Float }
        var ranked: [Ranked] = []
        var seen = Set<String>()

        func add(_ hit: SearchHit, _ score: Float) {
            if seen.insert(hit.id).inserted {
                ranked.append(Ranked(hit: hit, score: score))
            }
        }

        // Recency nudge: up to +0.05 for today, fading over 30 days.
        func recencyBoost(_ date: Date) -> Float {
            let days = max(0, -date.timeIntervalSinceNow / 86_400)
            return Float(max(0, 0.05 * (1 - days / 30)))
        }

        let db = Database.shared
        let lowered = q.lowercased()
        let clicks = loadClickStats()

        // 1. Keyword layer — FTS5 indexes, never LIKE table scans. Scores
        // 2.0 down to 1.7 so it always outranks the semantic layer.
        // Kind order within the tier: notes ≥ meetings > screenshots > dictations.
        let pattern = FTS5Pattern(matchingAllPrefixesIn: q)
        if let keyword = try? db.read({ db -> [(SearchHit, Float)] in
            var found: [(SearchHit, Float)] = []
            if let pattern {
                for note in try Note.fetchAll(db, sql: """
                    SELECT note.* FROM note
                    JOIN note_fts ON note_fts.rowid = note.rowid
                    WHERE note_fts MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [pattern, limit]) {
                    let titleMatch = note.title.lowercased().contains(lowered)
                    found.append((.note(note), titleMatch ? 2.0 : 1.9))
                }
                for meeting in try Meeting.fetchAll(db, sql: """
                    SELECT meeting.* FROM meeting
                    JOIN meeting_fts ON meeting_fts.rowid = meeting.rowid
                    WHERE meeting_fts MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [pattern, limit]) {
                    let titleMatch = meeting.title.lowercased().contains(lowered)
                    found.append((.meeting(meeting), titleMatch ? 2.0 : 1.88))
                }
                for shot in try Screenshot.fetchAll(db, sql: """
                    SELECT screenshot.* FROM screenshot
                    JOIN screenshot_fts ON screenshot_fts.rowid = screenshot.rowid
                    WHERE screenshot_fts MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [pattern, limit]) {
                    found.append((.screenshot(shot), 1.8))
                }
                for recording in try ScreenRecording
                    .filter(Column("transcript").like("%\(q)%") || Column("path").like("%\(q)%"))
                    .order(Column("createdAt").desc).limit(limit).fetchAll(db) {
                    found.append((.recording(recording), 1.75))
                }
                for row in try Row.fetchAll(db, sql: """
                    SELECT dictation.* FROM dictation
                    JOIN dictation_fts ON dictation_fts.rowid = dictation.rowid
                    WHERE dictation_fts MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [pattern, limit]) {
                    found.append((.dictation(DictationRecord(
                        id: row["id"], text: row["text"], createdAt: row["createdAt"])), 1.7))
                }
            } else {
                // Punctuation-only queries FTS can't tokenize: substring on
                // the small tables only (notes), never the transcript pile.
                for note in try Note
                    .filter(Column("body").like("%\(q)%") || Column("title").like("%\(q)%"))
                    .order(Column("updatedAt").desc).limit(limit).fetchAll(db) {
                    found.append((.note(note), 1.9))
                }
            }
            return found
        }) {
            for (hit, score) in keyword {
                add(hit, score + recencyBoost(hit.date)
                    + clickBoost(hitID: hit.id, kind: hit.kindLabel, query: lowered, stats: clicks))
            }
        }

        // 2. Semantic layer beneath — only if we can embed the query.
        if ranked.count < limit, let queryVector = embedding(for: q) {
            struct Scored { let hit: SearchHit; let score: Float }
            var scored: [Scored] = []

            if let rows = try? db.read({ db -> [(SearchHit, Data)] in
                var pairs: [(SearchHit, Data)] = []
                for note in try Note.fetchAll(db, sql: "SELECT * FROM note WHERE embedding IS NOT NULL ORDER BY updatedAt DESC LIMIT 400") {
                    if let blob = try Data.fetchOne(db, sql: "SELECT embedding FROM note WHERE id = ?", arguments: [note.id]) {
                        pairs.append((.note(note), blob))
                    }
                }
                for shot in try Screenshot.fetchAll(db, sql: "SELECT * FROM screenshot WHERE embedding IS NOT NULL ORDER BY createdAt DESC LIMIT 400") {
                    if let blob = try Data.fetchOne(db, sql: "SELECT embedding FROM screenshot WHERE id = ?", arguments: [shot.id]) {
                        pairs.append((.screenshot(shot), blob))
                    }
                }
                return pairs
            }) {
                let queryFloats: [Float] = queryVector.withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                for (hit, blob) in rows {
                    let score = cosine(queryFloats, decodedVector(id: hit.id, blob: blob))
                    if score > 0.55 {
                        scored.append(Scored(hit: hit, score: score))
                    }
                }
            }
            for item in scored {
                add(item.hit, item.score + recencyBoost(item.hit.date)
                    + clickBoost(hitID: item.hit.id, kind: item.hit.kindLabel, query: lowered, stats: clicks))
            }
        }

        return ranked
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.hit)
    }
}
