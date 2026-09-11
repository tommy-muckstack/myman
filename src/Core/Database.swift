import Foundation
import GRDB

// One local database for everything My Man captures — notes now; meeting
// transcripts and screenshot OCR join the same FTS index in later phases,
// which is what makes universal search possible.
enum Database {
    /// Shown once at launch when the prior SQLite store could not be opened.
    /// The original files are preserved in Application Support for recovery.
    private(set) static var startupRecoveryNotice: String?

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyMan", isDirectory: true)
    }

    private static var databaseURL: URL {
        directory.appendingPathComponent("myman.sqlite")
    }

    static var shared: DatabaseQueue = {
        do {
            return try openDatabase()
        } catch {
            // A migration/permission/disk error is not database corruption.
            // Never replace an intact library because a new migration failed.
            guard let databaseError = error as? DatabaseError,
                  databaseError.resultCode == .SQLITE_CORRUPT || databaseError.resultCode == .SQLITE_NOTADB else {
                fatalError("My Man could not open its database; the original library was left untouched: \(error.localizedDescription)")
            }
            // Preserve the failed store and its SQLite sidecars before making
            // a fresh one. A corrupt database must not turn into an app crash
            // or silently erase the only recoverable copy of a user's data.
            do {
                let backup = try backupFailedStore()
                let queue = try openDatabase()
                startupRecoveryNotice = "My Man repaired its local database. The previous files are saved in \(backup.lastPathComponent)."
                NSLog("My Man [Database] recovered from startup error: \(error)")
                return queue
            } catch {
                fatalError("My Man could not open its local database: \(error.localizedDescription)")
            }
        }
    }()

    private static func openDatabase() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(queue)
        return queue
    }

    private static func backupFailedStore() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = directory.appendingPathComponent(
            "Database Recovery \(formatter.string(from: Date()))", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.moveItem(at: source, to: backup.appendingPathComponent(source.lastPathComponent))
        }
        return backup
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-notes") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(virtualTable: "note_fts", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("body")
            }
        }

        migrator.registerMigration("v2-screenshots") { db in
            try db.create(table: "screenshot") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull()
                t.column("ocrText", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(virtualTable: "screenshot_fts", using: FTS5()) { t in
                t.synchronize(withTable: "screenshot")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("ocrText")
            }
        }

        migrator.registerMigration("v3-meetings-and-embeddings") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
                t.column("transcript", .text).notNull().defaults(to: "")
            }
            // On-device semantic search vectors (NLEmbedding), Float32 blobs.
            try db.alter(table: "note") { t in
                t.add(column: "embedding", .blob)
            }
            try db.alter(table: "screenshot") { t in
                t.add(column: "embedding", .blob)
            }
        }

        migrator.registerMigration("v4-search-clicks") { db in
            // Click log powering learned ranking (frecency + query affinity).
            try db.create(table: "searchClick") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("query", .text).notNull()
                t.column("hitID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("clickedAt", .datetime).notNull()
            }
            try db.create(indexOn: "searchClick", columns: ["hitID"])
        }

        migrator.registerMigration("v5-tasks") { db in
            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("source", .text).notNull() // meeting | note | dictation | manual
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
        }

        migrator.registerMigration("v6-meeting-summary") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "summary", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v7-dictations") { db in
            // Dictations are their own object: low-intent, context-specific
            // history — distinct from deliberate notes.
            try db.create(table: "dictation") { t in
                t.primaryKey("id", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v8-fts-meetings-dictations") { db in
            try db.create(virtualTable: "meeting_fts", using: FTS5()) { t in
                t.synchronize(withTable: "meeting")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("transcript")
            }
            try db.create(virtualTable: "dictation_fts", using: FTS5()) { t in
                t.synchronize(withTable: "dictation")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
        }

        migrator.registerMigration("v9-meeting-slides") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "slides", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v10-task-notes-due") { db in
            try db.alter(table: "task") { t in
                t.add(column: "notes", .text).notNull().defaults(to: "")
                t.add(column: "dueDate", .datetime)
            }
        }

        migrator.registerMigration("v11-recordings") { db in
            try db.create(table: "recording") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull()
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v12-people") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("meetCount", .integer).notNull().defaults(to: 0)
                t.column("firstMetAt", .datetime).notNull()
                t.column("lastMetAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v13-recording-transcript") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "transcript", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v14-unified-retrieval") { db in
            try CaptureSchema.create(in: db)
        }
        migrator.registerMigration("v15-grounded-meetings") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "meeting")
                t.add(column: "ownerName", .text).notNull().defaults(to: "")
                t.add(column: "participantsJSON", .text).notNull().defaults(to: "[]")
                t.add(column: "originalTranscript", .text).notNull().defaults(to: "")
                t.add(column: "analysisJSON", .text).notNull().defaults(to: "")
            }
            // Preserve existing source text before any explicit repair.
            try db.execute(sql: "UPDATE meeting SET originalTranscript = transcript")
            try db.alter(table: "task") { t in
                t.add(column: "archived", .boolean).notNull().defaults(to: false)
                t.add(column: "sourceMeetingID", .text).references("meeting", onDelete: .cascade)
                t.add(column: "sourceActionKey", .text)
            }
            try db.create(index: "task_meeting_action", on: "task", columns: ["sourceMeetingID", "sourceActionKey"], unique: true)
            // Reversible quarantine of the old extractor's quoted fragments.
            try db.execute(sql: """
                UPDATE task SET archived = 1 WHERE source = 'meeting' AND done = 0
                AND (trim(title) LIKE '"%' OR trim(title) LIKE '“%')
                """)
            // Attach uniquely recoverable legacy fragments to their meeting
            // so a later source deletion also removes the archived evidence.
            try db.execute(sql: """
                UPDATE task SET sourceMeetingID = (
                    SELECT id FROM meeting
                    WHERE instr(lower(transcript), lower(trim(task.title, '"“” '))) > 0
                ) WHERE source = 'meeting' AND archived = 1
                    AND length(trim(title, '"“” ')) >= 12
                    AND (SELECT count(*) FROM meeting
                         WHERE instr(lower(transcript), lower(trim(task.title, '"“” '))) > 0) = 1
                """)
            // Preserve useful dictation tasks while removing their old
            // transcript-style quotes. Invalid meeting fragments stay archived.
            for var task in try TaskItem.filter(Column("source") == "dictation").fetchAll(db) {
                if let cleaned = TaskHygiene.cleanQuotedTask(task.title), cleaned != task.title {
                    task.title = cleaned
                    try task.update(db)
                }
            }
            try db.alter(table: "person") { t in t.add(column: "hidden", .boolean).notNull().defaults(to: false) }
            try db.create(table: "vocabularyMention") { t in
                t.column("term", .text).notNull()
                t.column("meetingID", .text).notNull().references("meeting", onDelete: .cascade)
                t.primaryKey(["term", "meetingID"])
            }
            try db.create(table: "vocabularyDecision") { t in
                t.primaryKey("term", .text)
                t.column("accepted", .boolean).notNull()
            }
        }
        migrator.registerMigration("v16-conceptual-themes") { db in
            try db.alter(table: "captureTheme") { t in
                t.add(column: "description", .text).notNull().defaults(to: "")
                t.add(column: "conceptDigest", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v17-capture-context") { db in
            try db.create(table: "captureContext") { t in
                t.primaryKey("itemID", .text).references("captureItem", onDelete: .cascade)
                t.column("timezone", .text).notNull().defaults(to: "")
                t.column("meetingID", .text).references("meeting", onDelete: .setNull)
                for column in ["app", "bundleID", "windowTitle", "url", "imageVersion"] { t.column(column, .text).notNull().defaults(to: "") }
                t.column("analysisJSON", .text).notNull().defaults(to: "{}")
                t.column("thumbnail", .blob)
            }
            try db.execute(sql: "CREATE TRIGGER capture_context_exclude AFTER UPDATE OF excluded ON captureItem WHEN new.excluded=1 BEGIN DELETE FROM captureContext WHERE itemID=new.id; END")
        }
        return migrator
    }
}
