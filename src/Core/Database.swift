import Foundation
import GRDB

// One local database for everything My Man captures — notes now; meeting
// transcripts and screenshot OCR join the same FTS index in later phases,
// which is what makes universal search possible.
enum Database {
    static var shared: DatabaseQueue = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyMan", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try! DatabaseQueue(path: dir.appendingPathComponent("myman.sqlite").path)
        try! migrator.migrate(dbQueue)
        return dbQueue
    }()

    private static var migrator: DatabaseMigrator {
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

        return migrator
    }
}
