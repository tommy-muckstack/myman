import Foundation
import GRDB

/// Derived retrieval data only. Original capture tables remain authoritative.
enum CaptureSchema {
    static let sources: [(table: String, prefix: String, title: String, body: String, summary: String, path: String, date: String, modified: String)] = [
        ("note", "note", "title", "body", "''", "''", "createdAt", "updatedAt"),
        ("screenshot", "shot", "''", "ocrText", "''", "path", "createdAt", "createdAt"),
        ("meeting", "meeting", "title", "transcript", "summary", "''", "startedAt", "startedAt"),
        ("dictation", "dictation", "''", "text", "''", "''", "createdAt", "createdAt"),
        ("recording", "recording", "''", "transcript", "''", "path", "createdAt", "createdAt")
    ]

    static func create(in db: GRDB.Database) throws {
        // The chunk index replaces legacy first-1,000-character vectors.
        try db.execute(sql: "UPDATE note SET embedding = NULL; UPDATE screenshot SET embedding = NULL;")
        try db.execute(sql: """
            CREATE TABLE captureItem (
              id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, sourceID TEXT NOT NULL,
              rawTitle TEXT NOT NULL DEFAULT '', generatedTitle TEXT NOT NULL DEFAULT '',
              userTitle TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
              metadata TEXT NOT NULL DEFAULT '', sourcePath TEXT NOT NULL DEFAULT '',
              capturedAt DATETIME NOT NULL, modifiedAt DATETIME NOT NULL,
              pinned BOOLEAN NOT NULL DEFAULT 0, excluded BOOLEAN NOT NULL DEFAULT 0,
              revision INTEGER NOT NULL DEFAULT 1);
            CREATE INDEX capture_date ON captureItem(capturedAt DESC);
            CREATE INDEX capture_kind_date ON captureItem(kind, capturedAt DESC);
            CREATE TABLE capturePending (id TEXT PRIMARY KEY REFERENCES captureItem(id) ON DELETE CASCADE);
            CREATE TABLE captureChunk (
              itemID TEXT NOT NULL REFERENCES captureItem(id) ON DELETE CASCADE,
              ordinal INTEGER NOT NULL, field TEXT NOT NULL, text TEXT NOT NULL, embedding BLOB,
              PRIMARY KEY(itemID, ordinal));
            CREATE TABLE captureOCR (
              itemID TEXT PRIMARY KEY REFERENCES captureItem(id) ON DELETE CASCADE,
              lines BLOB NOT NULL, imageVersion TEXT NOT NULL);
            CREATE TABLE captureTheme (
              id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, signature TEXT NOT NULL UNIQUE,
              pinned BOOLEAN NOT NULL DEFAULT 0, dismissed BOOLEAN NOT NULL DEFAULT 0,
              renamed BOOLEAN NOT NULL DEFAULT 0);
            CREATE TABLE captureThemeMember (
              themeID TEXT NOT NULL REFERENCES captureTheme(id) ON DELETE CASCADE,
              itemID TEXT NOT NULL REFERENCES captureItem(id) ON DELETE CASCADE,
              manual BOOLEAN NOT NULL DEFAULT 0, blocked BOOLEAN NOT NULL DEFAULT 0,
              PRIMARY KEY(themeID, itemID));
            CREATE INDEX theme_item ON captureThemeMember(itemID);
            CREATE TABLE captureRelation (
              sourceID TEXT NOT NULL REFERENCES captureItem(id) ON DELETE CASCADE,
              targetID TEXT NOT NULL REFERENCES captureItem(id) ON DELETE CASCADE,
              score DOUBLE NOT NULL, kind TEXT NOT NULL, reason TEXT NOT NULL,
              PRIMARY KEY(sourceID, targetID, kind));
            CREATE INDEX relation_target ON captureRelation(targetID);
            """)
        try db.create(virtualTable: "capture_fts", using: FTS5()) { t in
            t.synchronize(withTable: "captureItem")
            t.tokenizer = .unicode61()
            for column in ["rawTitle", "generatedTitle", "userTitle", "body", "summary", "metadata", "sourcePath"] { t.column(column) }
        }
        try db.execute(sql: """
            CREATE VIRTUAL TABLE capture_vocab USING fts5vocab(capture_fts, 'row');
            CREATE TRIGGER capture_enrich_insert AFTER INSERT ON captureItem BEGIN
              INSERT INTO capturePending(id) SELECT new.id WHERE NOT EXISTS (SELECT 1 FROM capturePending WHERE id = new.id);
            END;
            CREATE TRIGGER capture_enrich_update AFTER UPDATE OF rawTitle,userTitle,body,summary,metadata,sourcePath ON captureItem
            WHEN old.rawTitle != new.rawTitle OR old.userTitle != new.userTitle OR old.body != new.body OR old.summary != new.summary OR old.metadata != new.metadata OR old.sourcePath != new.sourcePath
            BEGIN
              DELETE FROM captureChunk WHERE itemID = new.id;
              DELETE FROM captureRelation WHERE sourceID = new.id OR targetID = new.id;
              DELETE FROM captureThemeMember WHERE itemID = new.id AND manual = 0;
              INSERT INTO capturePending(id) SELECT new.id WHERE new.excluded = 0 AND NOT EXISTS (SELECT 1 FROM capturePending WHERE id = new.id);
            END;
            CREATE TRIGGER capture_exclusion AFTER UPDATE OF excluded ON captureItem BEGIN
              DELETE FROM captureChunk WHERE itemID = new.id;
              DELETE FROM captureRelation WHERE sourceID = new.id OR targetID = new.id;
              DELETE FROM captureThemeMember WHERE itemID = new.id;
              DELETE FROM capturePending WHERE id = new.id;
              INSERT INTO capturePending(id) SELECT new.id WHERE new.excluded = 0 AND NOT EXISTS (SELECT 1 FROM capturePending WHERE id = new.id);
            END;
            CREATE TRIGGER capture_cleanup AFTER DELETE ON captureItem BEGIN
              DELETE FROM searchClick WHERE hitID = old.id;
              DELETE FROM captureTheme WHERE dismissed = 0 AND renamed = 0 AND pinned = 0 AND id NOT IN (SELECT themeID FROM captureThemeMember);
            END;
            """)
        for source in sources {
            func expression(_ column: String, prefix: String = "") -> String { column == "''" ? column : prefix + column }
            let columns = "id,kind,sourceID,rawTitle,body,summary,sourcePath,capturedAt,modifiedAt"
            func values(_ p: String) -> String {
                "'\(source.prefix)-' || \(p)id, '\(source.table)', \(p)id, " +
                [source.title, source.body, source.summary, source.path, source.date, source.modified]
                    .map { expression($0, prefix: p) }.joined(separator: ",")
            }
            let upsert = """
                INSERT INTO captureItem(\(columns)) VALUES(\(values("new.")))
                ON CONFLICT(id) DO UPDATE SET rawTitle=excluded.rawTitle,body=excluded.body,
                  summary=excluded.summary,sourcePath=excluded.sourcePath,
                  capturedAt=excluded.capturedAt,modifiedAt=excluded.modifiedAt,
                  revision=captureItem.revision + CASE WHEN captureItem.rawTitle != excluded.rawTitle OR captureItem.body != excluded.body OR captureItem.summary != excluded.summary OR captureItem.sourcePath != excluded.sourcePath THEN 1 ELSE 0 END,
                  generatedTitle=CASE WHEN captureItem.rawTitle != excluded.rawTitle OR captureItem.body != excluded.body OR captureItem.summary != excluded.summary OR captureItem.sourcePath != excluded.sourcePath THEN '' ELSE captureItem.generatedTitle END;
                """
            try db.execute(sql: """
                INSERT INTO captureItem(\(columns)) SELECT \(values("")) FROM \(source.table);
                CREATE TRIGGER capture_\(source.table)_insert AFTER INSERT ON \(source.table) BEGIN \(upsert) END;
                CREATE TRIGGER capture_\(source.table)_update AFTER UPDATE ON \(source.table) BEGIN \(upsert) END;
                CREATE TRIGGER capture_\(source.table)_delete AFTER DELETE ON \(source.table) BEGIN
                  DELETE FROM captureItem WHERE id = '\(source.prefix)-' || old.id;
                END;
                """)
        }
    }
}
