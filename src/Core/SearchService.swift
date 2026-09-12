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
    static var semanticAvailable: Bool { embedder != nil }
    private static let embeddingLock = NSLock()

    static func embedding(for text: String) -> Data? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        let trimmed = String(text.prefix(1000))
        guard !trimmed.isEmpty,
              let vector = embedder?.vector(for: trimmed.lowercased()) else { return nil }
        let floats = vector.map(Float.init)
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decoded-vector cache: blobs decode once, not on every keystroke.
    private static let cacheLock = NSLock()
    private struct VectorKey: Hashable { let id: String; let blob: Data }
    private static var vectorCache: [VectorKey: [Float]] = [:]

    static func clearVectorCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        vectorCache.removeAll()
    }

    static func decodedVector(id: String, blob: Data) -> [Float] {
        let key = VectorKey(id: id, blob: blob)
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
        let type = ["voice": "dictation", "record": "recording"][kind] ?? kind
        guard CaptureSchema.sources.contains(where: { $0.table == type }) else { return [] }
        return (try? Database.shared.read { db in
            try CaptureItem.fetchAll(db, sql: "SELECT * FROM captureItem WHERE kind = ? AND excluded = 0 ORDER BY capturedAt DESC LIMIT ?", arguments: [type, limit]).compactMap { try $0.hit(in: db) }
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

    // MARK: Query

    /// Ranked results: keyword matches score highest (title beats body,
    /// recency breaks ties), semantic hits fill in beneath by cosine
    /// similarity. Everything local, degrades silently.
    static func search(_ query: String, limit: Int = 8) -> [SearchHit] {
        do {
            let first = try CaptureIndex.lexical(query, limit: limit)
            let enabled = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
            let matches = try CaptureIndex.expanded(query, lexical: first, limit: limit, semantic: enabled)
            return try Database.shared.read { db in try matches.compactMap { try $0.item.hit(in: db) } }
        } catch { return [] }
    }
}
