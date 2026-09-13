import AppKit
import Foundation
import GRDB

enum CaptureLifecycle {
    private static func checkRevision(_ id: String, expected: Int?, db: GRDB.Database) throws {
        if let expected, try Int.fetchOne(db, sql: "SELECT revision FROM captureItem WHERE id=?", arguments: [id]) != expected { throw AgentError("EDIT_CONFLICT", "Item changed; read it again.") }
    }
    static func exists(kind: String, id: String) -> Bool {
        guard CaptureSchema.sources.contains(where: { $0.table == kind }) else { return false }
        return (try? Database.shared.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(kind) WHERE id = ?", arguments: [id]) }) == 1
    }

    static func pin(_ item: CaptureItem, expectedRevision: Int? = nil) throws {
        try Database.shared.write { try checkRevision(item.id, expected: expectedRevision, db: $0); try $0.execute(sql: "UPDATE captureItem SET pinned = ?, revision = revision + 1 WHERE id = ?", arguments: [!item.pinned, item.id]) }
        ThemeStore.notify()
    }
    static func rename(_ item: CaptureItem, title: String, expectedRevision: Int? = nil) throws {
        try Database.shared.write { try checkRevision(item.id, expected: expectedRevision, db: $0); try $0.execute(sql: "UPDATE captureItem SET userTitle = ?, revision = revision + 1 WHERE id = ?", arguments: [String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)), item.id]) }
        ThemeStore.notify()
    }
    static func exclude(_ item: CaptureItem, excluded: Bool, expectedRevision: Int? = nil) throws {
        try Database.shared.write { try checkRevision(item.id, expected: expectedRevision, db: $0); try $0.execute(sql: "UPDATE captureItem SET excluded = ?, revision = revision + 1 WHERE id = ?", arguments: [excluded, item.id]) }
        SearchService.clearVectorCache()
        if excluded { NotificationCenter.default.post(name: .captureExcluded, object: item.id) }
        ThemeStore.notify()
    }

    @MainActor static func delete(_ item: CaptureItem, expectedRevision: Int? = nil) throws {
        let hit = try Database.shared.read { try checkRevision(item.id, expected: expectedRevision, db: $0); return try item.hit(in: $0) }
        guard let hit else { return }
        var files: [String] = []
        switch hit {
        case .screenshot(let s): files = [s.path]
        case .recording(let r): files = [r.path]
        case .meeting(let m): files = [m.micAudioPath, m.systemAudioPath].compactMap { $0 } + m.slidePaths
        default: break
        }
        if item.kind == "note" || item.kind == "meeting" {
            files += DocumentAssets.shared.ownedFiles(documentID: item.kind + "-" + item.sourceID).map(\.path)
        }
        // If trashing fails, keep the row so users can retry rather than lose
        // the only reference to a surviving sensitive file.
        for file in files where FileManager.default.fileExists(atPath: file) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: file), resultingItemURL: nil)
        }
        try Database.shared.write { db in
            try db.execute(sql: "DELETE FROM \(item.kind) WHERE id = ?", arguments: [item.sourceID])
        }
        switch hit {
        case .note(let n): Brain.deleteNote(id: n.id, createdAt: n.createdAt)
        case .screenshot(let s): Brain.deleteScreenshot(id: s.id, createdAt: s.createdAt)
        case .meeting(let m):
            Brain.deleteMeeting(id: m.id, startedAt: m.startedAt)
            TasksStore.shared.refresh()
        case .recording(let r): Brain.deleteRecording(id: r.id, createdAt: r.createdAt)
        case .dictation: break
        }
        SearchService.clearVectorCache()
        CaptureThumbnailCache.clear()
        SlideThumbnailer.clear()
        NoteDocumentController.shared.close(id: item.sourceID)
        MeetingDocumentController.shared.close(id: item.sourceID)
        for window in NSApp.windows where files.contains(window.representedURL?.path ?? "") {
            window.contentView = nil
            window.close()
        }
        NotificationCenter.default.post(name: .captureDeleted, object: item.id)
        ThemeStore.notify()
    }

    @MainActor static func clearHistory() throws {
        let all = try Database.shared.read { try CaptureItem.fetchAll($0) }
        for item in all { try delete(item) }
        try Database.shared.write { db in
            try db.execute(sql: "DELETE FROM searchClick; DELETE FROM captureTheme; DELETE FROM task WHERE source = 'meeting' AND archived = 1;")
        }
    }
}

extension Notification.Name { static let captureDeleted = Notification.Name("man.captureDeleted"); static let captureExcluded = Notification.Name("man.captureExcluded") }
