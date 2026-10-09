import Foundation
import GRDB

/// What the Settings page shows about the Brainz index.
@MainActor final class BrainIndexStatus: ObservableObject {
    static let shared = BrainIndexStatus()
    @Published var root: URL?
    @Published var count = 0
    @Published var lastScan: Date?
    @Published var isScanning = false
    @Published var lastError: String?
}

/// Walks the Brainz workspace folder and mirrors its Markdown files into the
/// `brainNote` table, which the capture triggers fan out into search. Read
/// only: files are never modified, moved or deleted. Scans are incremental on
/// modification time and size, so the launch and periodic passes are cheap.
final class BrainNoteIndexer: @unchecked Sendable {
    static let shared = BrainNoteIndexer()
    static let defaultExcludedFolders = ["finances", "health", "family", ".claude", ".git", "node_modules"]
    static let scanInterval: TimeInterval = 600

    struct Options: Sendable {
        var root: URL
        var excludedFolders: Set<String> = Set(BrainNoteIndexer.defaultExcludedFolders)
        var maxFileSize = 512 * 1024
        /// Folders never indexed even when the brain contains them, so a
        /// brain that includes `~/MyManBrain` cannot re-index My Man's own
        /// exports.
        var skipRoots: [URL] = [Brain.root]
        /// Tests index into their own database and must not poke the app's
        /// enrichment worker.
        var schedulesEnrichment = true
    }

    struct Report: Equatable, Sendable {
        var scanned = 0
        var added = 0
        var updated = 0
        var removed = 0
        var skipped = 0
        var duration: TimeInterval = 0
    }

    private let database: DatabaseQueue
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.muckstack.myman.brain-notes", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var settingsObserver: Any?

    init(database: DatabaseQueue = Database.shared, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
    }

    /// Scans once now and every ten minutes after. Safe to call once at launch.
    func start() {
        rescan(reason: "launch")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.scanInterval, repeating: Self.scanInterval)
        timer.setEventHandler { [weak self] in self?.performScan(reason: "periodic") }
        timer.resume()
        self.timer = timer
    }

    /// Runs a scan off the main thread. Settings changes and meeting starts
    /// call this so fresh notes are available right away.
    func rescan(reason: String) {
        queue.async { [weak self] in self?.performScan(reason: reason) }
    }

    private func performScan(reason: String) {
        let settings = DispatchQueue.main.sync { (SettingsStore.shared.brainFolderPath, SettingsStore.shared.brainExcludedFolders) }
        guard let root = BrainWorkspace.discover(pickedPath: settings.0, fileManager: fileManager) else {
            DispatchQueue.main.async {
                BrainIndexStatus.shared.root = nil
                BrainIndexStatus.shared.count = 0
            }
            return
        }
        DispatchQueue.main.async {
            BrainIndexStatus.shared.root = root
            BrainIndexStatus.shared.isScanning = true
        }
        var options = Options(root: root)
        options.excludedFolders = Set(settings.1.map { $0.lowercased() })
        do {
            let report = try scan(options)
            let count = (try? database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM brainNote") }) ?? 0
            DispatchQueue.main.async {
                let status = BrainIndexStatus.shared
                status.count = count
                status.lastScan = Date()
                status.isScanning = false
                status.lastError = nil
            }
            if report.added + report.updated + report.removed > 0 || reason == "launch" {
                Analytics.track("brain_index_completed", ["reason": reason, "notes": count, "added": report.added,
                                                          "updated": report.updated, "removed": report.removed,
                                                          "skipped": report.skipped, "duration_ms": Int(report.duration * 1000)])
            }
        } catch {
            NSLog("My Man [Brainz] scan failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                BrainIndexStatus.shared.isScanning = false
                BrainIndexStatus.shared.lastError = error.localizedDescription
            }
        }
    }

    /// Synchronous, so tests can drive it against a temporary folder.
    @discardableResult func scan(_ options: Options) throws -> Report {
        let started = Date()
        var report = Report()
        let existing: [String: (id: String, mtime: Double, size: Int)] = try database.read { db in
            var map: [String: (String, Double, Int)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, path, mtime, size FROM brainNote") {
                map[row["path"]] = (row["id"], row["mtime"], row["size"])
            }
            return map
        }
        let skipRoots = options.skipRoots.map { $0.standardizedFileURL.path }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .creationDateKey, .nameKey]
        guard let enumerator = fileManager.enumerator(at: options.root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return report
        }
        var seen = Set<String>()
        var pending: [BrainNote] = []
        func flush() throws {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = []
            try database.write { db in
                for note in batch {
                    try db.execute(sql: """
                        INSERT INTO brainNote(id, path, title, body, createdAt, updatedAt, mtime, size)
                        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET title=excluded.title, body=excluded.body,
                          updatedAt=excluded.updatedAt, mtime=excluded.mtime, size=excluded.size
                        """, arguments: [note.id, note.path, note.title, note.body, note.createdAt, note.updatedAt, note.mtime, note.size])
                }
            }
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.standardizedFileURL.path
            if values.isDirectory == true {
                let name = (values.name ?? url.lastPathComponent).lowercased()
                if options.excludedFolders.contains(name) || skipRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    report.skipped += 1
                }
                continue
            }
            guard BrainWorkspace.isMarkdown(url) else { continue }
            report.scanned += 1
            let size = values.fileSize ?? 0
            guard size <= options.maxFileSize else { report.skipped += 1; continue }
            let modified = values.contentModificationDate ?? Date()
            let mtime = modified.timeIntervalSince1970
            seen.insert(path)
            if let known = existing[path], known.mtime == mtime, known.size == size { continue }
            guard let data = fileManager.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                report.skipped += 1
                continue
            }
            let parsed = BrainNote.parse(markdown: text, filename: url.lastPathComponent)
            let created = values.creationDate ?? modified
            pending.append(BrainNote(id: BrainNote.id(forPath: path), path: path, title: parsed.title, body: parsed.body,
                                     createdAt: created, updatedAt: modified, mtime: mtime, size: size))
            if existing[path] == nil { report.added += 1 } else { report.updated += 1 }
            if pending.count >= 50 { try flush() }
        }
        try flush()
        let vanished = existing.keys.filter { !seen.contains($0) }
        if !vanished.isEmpty {
            try database.write { db in
                for path in vanished { try db.execute(sql: "DELETE FROM brainNote WHERE path = ?", arguments: [path]) }
            }
            report.removed = vanished.count
        }
        if report.added + report.updated + report.removed > 0, options.schedulesEnrichment {
            SearchService.clearVectorCache()
            CaptureEnrichment.shared.schedule()
        }
        report.duration = Date().timeIntervalSince(started)
        return report
    }
}
