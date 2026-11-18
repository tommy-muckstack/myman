import AppKit
import Foundation
import GRDB

final class CaptureEnrichment: TransactionObserver, @unchecked Sendable {
    static let shared = CaptureEnrichment()
    private let database: DatabaseQueue
    private var maintenance: CoalescingMaintenance!
    private var relationships = CaptureRelationships()
    private var changed = false // Only touched on GRDB's transaction queue.
    private var deleted = false
    private var started = false

    init(database: DatabaseQueue = Database.shared) {
        self.database = database
        maintenance = CoalescingMaintenance(label: "man.capture.enrichment") { [weak self] _ in self?.process() }
    }

    func start() {
        guard !started else { return }
        started = true
        database.add(transactionObserver: self)
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

    func schedule() { maintenance.request() }

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
        if item.kind == "screenshot" { return ScreenshotIntelligence.title(text: item.body) }
        let candidates = item.body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let line = candidates.first { value in
            let words = CaptureText.words(value)
            return value.count >= 8 && words.filter { !CaptureSignals.stopWords.contains($0) }.count >= 2
        } ?? ""
        guard !line.isEmpty else { return "" }
        return String(line.prefix(85)) + (line.count > 85 ? "…" : "")
    }

    private func process() {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let batch = try database.read { db in
                try CaptureItem.fetchAll(db, sql: "SELECT c.* FROM capturePending p JOIN captureItem c ON c.id = p.id WHERE c.excluded = 0 ORDER BY c.capturedAt DESC LIMIT 8")
            }
            let semantics = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
            for item in batch {
                if BackgroundMaintenance.shouldDefer { schedule(); return }
                let chunks = Self.chunks(item).map { field, text in (field, text, semantics ? SearchService.embedding(for: text) : nil) }
                let title: String
                if item.kind == "screenshot", let context = try database.read({ try ScreenshotContext.fetchOne($0, key: item.id) }), !context.imageVersion.isEmpty {
                    title = item.generatedTitle.isEmpty ? ScreenshotIntelligence.title(text: item.body, window: context.windowTitle) : item.generatedTitle
                } else { title = Self.generatedTitle(item) }
                try database.write { db in
                    // Edits/deletes during inference must not reintroduce stale
                    // text or resurrect a deleted capture.
                    guard let current = try CaptureItem.fetchOne(db, key: item.id), current.revision == item.revision, !current.excluded else { return }
                    let stillSemantic = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
                    try db.execute(sql: "DELETE FROM captureChunk WHERE itemID = ?", arguments: [item.id])
                    for (index, chunk) in chunks.enumerated() {
                        try db.execute(sql: "INSERT INTO captureChunk(itemID,ordinal,field,text,embedding) VALUES (?,?,?,?,?)", arguments: [item.id, index, chunk.0, chunk.1, stillSemantic ? chunk.2 : nil])
                    }
                    if current.generatedTitle != title {
                        try db.execute(sql: "UPDATE captureItem SET generatedTitle = ? WHERE id = ?", arguments: [title, item.id])
                    }
                    try db.execute(sql: "DELETE FROM capturePending WHERE id = ?", arguments: [item.id])
                }
            }
            let more = try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capturePending p JOIN captureItem c ON c.id = p.id WHERE c.excluded = 0") ?? 0 }
            if !batch.isEmpty {
                NSLog("My Man maintenance: enrichment items=%d duration_ms=%d", batch.count,
                      Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            }
            if more > 0 { schedule(); return }
            try rebuildRelationships()
            Task(priority: .background) { await ConceptThemeWorker.shared.schedule() }
            ThemeStore.notify()
        } catch { NSLog("Man: capture enrichment will retry after the next change: %@", error.localizedDescription) }
    }

    @discardableResult func rebuildRelationships() throws -> CaptureRelationships.Update? {
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try database.read { try CaptureItem.filter(Column("excluded") == false).fetchAll($0) }
        guard let update = relationships.prepare(snapshot) else { return nil }
        let applied = try database.write { db -> Bool in
            let current = try CaptureItem.filter(Column("excluded") == false).fetchAll(db)
            guard CaptureRelationships.versions(current) == CaptureRelationships.versions(snapshot) else { return false }
            if update.reset {
                try db.execute(sql: "DELETE FROM captureRelation")
            } else {
                for id in update.sources {
                    try db.execute(sql: "DELETE FROM captureRelation WHERE sourceID = ?", arguments: [id])
                }
            }
            for edge in update.edges {
                try db.execute(sql: "INSERT OR REPLACE INTO captureRelation(sourceID,targetID,score,kind,reason) VALUES (?,?,?,?,?)",
                               arguments: [edge.source, edge.target, edge.score, edge.kind, edge.reason])
            }
            return true
        }
        guard applied else { schedule(); return nil }
        relationships = update.next
        NSLog("My Man maintenance: relationships items=%d analyzed=%d sources=%d pairs=%d duration_ms=%d",
              snapshot.count, update.analyzedItems, update.sources.count, update.scoredPairs,
              Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        return update
    }
}
