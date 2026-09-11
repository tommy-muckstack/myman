import AppKit
import Foundation
import GRDB

enum OCRStore {
    /// Conservative paragraph grouping using adjacent line geometry. Separate
    /// columns and distant labels remain independent copyable regions.
    static func paragraphs(_ lines: [ImageAnalysis.TextObservation]) -> [ImageAnalysis.TextObservation] {
        var groups: [ImageAnalysis.TextObservation] = []
        for line in lines {
            if let previous = groups.last,
               abs(previous.box.minX - line.box.minX) < 0.025,
               previous.box.minY >= line.box.maxY - 0.005,
               previous.box.minY - line.box.maxY < max(0.012, line.box.height * 0.85) {
                groups[groups.count - 1] = ImageAnalysis.TextObservation(id: previous.id, text: previous.text + "\n" + line.text, box: previous.box.union(line.box))
            } else { groups.append(line) }
        }
        return groups
    }

    static func invalidate(path: String) throws {
        let records = try Database.shared.write { db in
            let records = try Screenshot.filter(Column("path") == path).fetchAll(db)
            try db.execute(sql: "UPDATE screenshot SET ocrText = '', embedding = NULL WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM captureOCR WHERE itemID IN (SELECT id FROM captureItem WHERE sourcePath = ?)", arguments: [path])
            try db.execute(sql: "UPDATE captureContext SET analysisJSON='{}',thumbnail=NULL,imageVersion='' WHERE itemID IN (SELECT id FROM captureItem WHERE sourcePath=?)", arguments: [path])
            try db.execute(sql: "UPDATE captureItem SET metadata = '', generatedTitle = '', revision = revision + 1 WHERE sourcePath = ?", arguments: [path])
            return records
        }
        for record in records { Brain.syncScreenshot(id: record.id, filePath: path, ocrText: "", createdAt: record.createdAt) }
        SearchService.clearVectorCache(); CaptureThumbnailCache.clear(); ThemeStore.notify()
    }
    static func version(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        return "\(date.timeIntervalSince1970):\(size)"
    }

    static func lines(itemID: String, database: DatabaseQueue = Database.shared) -> [ImageAnalysis.TextObservation] {
        (try? database.read { db in
            guard let item = try CaptureItem.fetchOne(db, key: itemID),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM captureOCR WHERE itemID = ?", arguments: [itemID]),
                  row["imageVersion"] as String == version(URL(fileURLWithPath: item.sourcePath)) else { return [] }
            let data: Data = row["lines"]
            return try JSONDecoder().decode([ImageAnalysis.TextObservation].self, from: data)
        }) ?? []
    }

    static func refresh(image: NSImage, fileURL: URL, id: String? = nil) {
        guard let expected = version(fileURL) else { return }
        Task.detached(priority: .utility) {
            let record: Screenshot? = try? await Database.shared.read { db in
                if let id { return try Screenshot.fetchOne(db, key: id) }
                return try Screenshot.filter(Column("path") == fileURL.path).fetchOne(db)
            }
            guard let record else { return }
            await analyze(image: image, record: record, expected: expected)
        }
    }

    private static func analyze(image: NSImage, record: Screenshot, expected: String) async {
        let result = await ImageAnalysis.analyze(image)
        guard let data = try? JSONEncoder().encode(result.observations) else { return }
        let url = URL(fileURLWithPath: record.path)
        let text = paragraphs(result.observations).map(\.text).joined(separator: "\n\n")
        let prepared = try? ScreenshotContext.prepare(image: image, lines: result.observations, text: text)
        let saved = (try? await Database.shared.write { db -> Bool in
            guard version(url) == expected, try Screenshot.fetchOne(db, key: record.id) != nil else { return false }
            let text = paragraphs(result.observations).map(\.text).joined(separator: "\n\n")
            try db.execute(sql: "UPDATE screenshot SET ocrText = ?, embedding = NULL WHERE id = ?", arguments: [text, record.id])
            let labels = result.labels.joined(separator: " ")
            try db.execute(sql: "UPDATE captureItem SET metadata = ?, revision = revision + 1 WHERE id = ? AND metadata != ?", arguments: [labels, "shot-" + record.id, labels])
            try db.execute(sql: "INSERT OR REPLACE INTO captureOCR(itemID,lines,imageVersion) VALUES (?,?,?)", arguments: ["shot-" + record.id, data, expected])
            if let prepared { try ScreenshotContext.saveAnalysis(prepared, itemID: "shot-" + record.id, version: expected, in: db) }
            return true
        }) ?? false
        if saved {
            Brain.syncScreenshot(id: record.id, filePath: record.path, ocrText: paragraphs(result.observations).map(\.text).joined(separator: "\n\n"), createdAt: record.createdAt)
            ThemeStore.notify()
        }
    }

    /// One image at a time, only previously saved intentional screenshots.
    /// No screen polling and no repeated OCR for already-versioned files.
    static func backfill() {
        Task.detached(priority: .background) {
            let records = (try? await Database.shared.read { db in
                try Screenshot.fetchAll(db, sql: "SELECT s.* FROM screenshot s JOIN captureItem c ON c.sourceID = s.id AND c.kind = 'screenshot' WHERE c.excluded = 0 ORDER BY s.createdAt DESC")
            }) ?? []
            for record in records {
                guard !Task.isCancelled else { break }
                let url = URL(fileURLWithPath: record.path)
                guard let expected = version(url) else { continue }
                let stored = try? await Database.shared.read { try String.fetchOne($0, sql: "SELECT imageVersion FROM captureOCR WHERE itemID = ?", arguments: ["shot-" + record.id]) }
                let contextVersion = try? await Database.shared.read { try ScreenshotContext.fetchOne($0, key: "shot-" + record.id)?.imageVersion }
                if stored == expected, contextVersion == expected { continue }
                guard let image = NSImage(contentsOf: url) else { continue }
                if stored == expected {
                    let observations = lines(itemID: "shot-" + record.id)
                    if let prepared = try? ScreenshotContext.prepare(image: image, lines: observations, text: record.ocrText) {
                        try? await Database.shared.write { db in
                            guard version(url) == expected else { return }
                            try ScreenshotContext.saveAnalysis(prepared, itemID: "shot-" + record.id, version: expected, in: db)
                        }
                    }
                    continue
                }
                await analyze(image: image, record: record, expected: expected)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
