import AppKit
import Foundation
import GRDB

final class CaptureEnrichment: TransactionObserver, @unchecked Sendable {
    static let shared = CaptureEnrichment()
    private let queue = DispatchQueue(label: "man.capture.enrichment", qos: .utility)
    private var pending: DispatchWorkItem?
    private var changed = false // Only touched on GRDB's transaction queue.
    private var deleted = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Database.shared.add(transactionObserver: self)
        schedule()
        OCRStore.backfill()
    }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { ["captureItem", "capturePending"].contains(eventKind.tableName) }
    func databaseDidChange(with event: DatabaseEvent) {
        changed = true
        if event.tableName == "captureItem", event.kind == .delete { deleted = true }
    }
    func databaseDidCommit(_ db: GRDB.Database) {
        if deleted {
            deleted = false
            SearchService.clearVectorCache(); CaptureThumbnailCache.clear(); SlideThumbnailer.clear()
        }
        if changed { changed = false; schedule(); ThemeStore.notify() }
    }
    func databaseDidRollback(_ db: GRDB.Database) { changed = false; deleted = false }

    func schedule() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.process() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    static func chunks(_ item: CaptureItem) -> [(String, String)] {
        var output: [(String, String)] = []
        for (field, text) in [("title", item.title), (item.kind == "screenshot" ? "screenshot text" : "transcript or note", item.body), ("meeting notes", item.summary), ("metadata", item.metadata)] {
            guard !text.isEmpty else { continue }
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
                output.append((field, String(text[start..<end])))
                if end == text.endIndex { break }
                start = text.index(end, offsetBy: -100, limitedBy: start) ?? end
            }
        }
        return output
    }

    static func generatedTitle(_ item: CaptureItem) -> String {
        guard item.rawTitle.isEmpty, ["screenshot", "recording", "dictation"].contains(item.kind) else { return "" }
        let candidates = item.body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let line = candidates.first { value in
            let words = CaptureText.words(value)
            return value.count >= 8 && words.filter { !CaptureSignals.stopWords.contains($0) }.count >= 2
        } ?? ""
        guard !line.isEmpty else { return "" }
        return String(line.prefix(85)) + (line.count > 85 ? "…" : "")
    }

    private func process() {
        do {
            let batch = try Database.shared.read { db in
                try CaptureItem.fetchAll(db, sql: "SELECT c.* FROM capturePending p JOIN captureItem c ON c.id = p.id WHERE c.excluded = 0 ORDER BY c.capturedAt DESC LIMIT 8")
            }
            let semantics = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
            for item in batch {
                let chunks = Self.chunks(item).map { field, text in (field, text, semantics ? SearchService.embedding(for: text) : nil) }
                let title = Self.generatedTitle(item)
                try Database.shared.write { db in
                    // Edits/deletes during inference must not reintroduce stale
                    // text or resurrect a deleted capture.
                    guard let current = try CaptureItem.fetchOne(db, key: item.id), current.revision == item.revision, !current.excluded else { return }
                    let stillSemantic = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
                    try db.execute(sql: "DELETE FROM captureChunk WHERE itemID = ?", arguments: [item.id])
                    for (index, chunk) in chunks.enumerated() {
                        try db.execute(sql: "INSERT INTO captureChunk(itemID,ordinal,field,text,embedding) VALUES (?,?,?,?,?)", arguments: [item.id, index, chunk.0, chunk.1, stillSemantic ? chunk.2 : nil])
                    }
                    try db.execute(sql: "UPDATE captureItem SET generatedTitle = ? WHERE id = ?", arguments: [title, item.id])
                    try db.execute(sql: "DELETE FROM capturePending WHERE id = ?", arguments: [item.id])
                }
            }
            let more = try Database.shared.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capturePending") ?? 0 }
            if more > 0 { schedule(); return }
            try rebuildRelationships()
            Task(priority: .background) { await ConceptThemeWorker.shared.schedule() }
            ThemeStore.notify()
        } catch { NSLog("Man: capture enrichment will retry after the next change: %@", error.localizedDescription) }
    }

    private func rebuildRelationships() throws {
        let snapshot = try Database.shared.read { try CaptureItem.filter(Column("excluded") == false).fetchAll($0) }
        // Compute thematic evidence off the DB queue, then apply short writes.
        // Candidate pruning uses shared terms or nearby dates, not every pair.
        var inverted: [String: Set<Int>] = [:]
        var terms: [Set<String>] = []
        let domains = snapshot.map { CaptureSignals.domains($0.text) }
        var domainPeers: [String: Set<Int>] = [:]
        for (index, item) in snapshot.enumerated() {
            let words = CaptureSignals.terms(item)
            terms.append(words)
            for term in words { inverted[term, default: []].insert(index) }
            for domain in domains[index] { domainPeers[domain, default: []].insert(index) }
        }
        var edges: [(String, String, Double, String, String)] = []
        for (index, item) in snapshot.enumerated() {
            var counts: [Int: Int] = [:]
            for domain in domains[index] {
                for peer in (domainPeers[domain] ?? []) where peer != index { counts[peer, default: 0] += 2 }
            }
            for term in terms[index] {
                guard let peers = inverted[term], peers.count <= max(20, snapshot.count / 3) else { continue }
                for peer in peers where peer != index { counts[peer, default: 0] += 1 }
            }
            let candidates = counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(30)
            for (peer, _) in candidates {
                if let (score, kind, reason) = RelatedItems.score(item, snapshot[peer], sharedTerms: terms[index].intersection(terms[peer]), sharedDomains: domains[index].intersection(domains[peer])) { edges.append((item.id, snapshot[peer].id, score, kind, reason)) }
            }
        }
        try Database.shared.write { db in
            // A changed snapshot is retried rather than applied over edits.
            let current = try CaptureItem.filter(Column("excluded") == false).fetchAll(db)
            guard Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.revision) }) == Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.revision) }) else { return }
            try db.execute(sql: "DELETE FROM captureRelation")
            for edge in edges {
                try db.execute(sql: "INSERT OR REPLACE INTO captureRelation(sourceID,targetID,score,kind,reason) VALUES (?,?,?,?,?)", arguments: [edge.0, edge.1, edge.2, edge.3, edge.4])
            }
            // Theme relationships are joined at retrieval time. Materializing
            // every pair would grow quadratically in a large theme.
        }
    }
}
