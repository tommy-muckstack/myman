import Foundation
import GRDB

/// Extends the existing portable Brain. The database remains authoritative;
/// this catalog contains retrieval metadata, never a second search index.
enum BrainAgentExport {
    struct ThemeRef: Codable, Equatable { var id: String; var title: String }
    struct Entry: Codable {
        var path: String
        var kind: String
        var title: String
        var timestamp: String
        var themes: [ThemeRef] = []
        var pinned: Bool = false
        var done: Bool? = nil
        var image_path: String? = nil
    }
    struct Catalog: Codable {
        var version = 1
        var generated_at: String
        var exports: [Entry]
    }
    struct Snapshot {
        var catalog: Catalog
        var documents: [String: String]
    }
    struct Source {
        var items: [CaptureItem]
        var meetings: [String: Row]
        var recordings: [String: Int]
        var memberships: [Row]
        var tasks: [Row]
        var themes: [Row]
    }

    static func source(in db: GRDB.Database) throws -> Source {
        let items = try CaptureItem.filter(Column("excluded") == false).order(Column("id")).fetchAll(db)
        let meetings = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM meeting").map { ($0["id"] as String, $0) })
        let recordings = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,duration FROM recording").map { ($0["id"] as String, $0["duration"] as Int) })
        let memberships = try Row.fetchAll(db, sql: """
            SELECT m.itemID,t.id,t.title FROM captureThemeMember m
            JOIN captureTheme t ON t.id=m.themeID JOIN captureItem c ON c.id=m.itemID
            WHERE m.blocked=0 AND t.dismissed=0 AND c.excluded=0 ORDER BY t.id,m.itemID
            """)
        let archived = try db.columns(in: "task").contains { $0.name == "archived" }
        let tasks = try Row.fetchAll(db, sql: "SELECT * FROM task\(archived ? " WHERE archived=0" : "") ORDER BY id")
        let themes = try Row.fetchAll(db, sql: "SELECT * FROM captureTheme WHERE dismissed=0 ORDER BY id")
        return Source(items: items, meetings: meetings, recordings: recordings, memberships: memberships, tasks: tasks, themes: themes)
    }

    static func snapshot(in db: GRDB.Database) throws -> Snapshot { snapshot(source: try source(in: db)) }

    static func snapshot(source: Source) -> Snapshot {
        let items = source.items, meetings = source.meetings, recordings = source.recordings
        // Serialization and formatting run after releasing the database read.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"
        let iso: (Date) -> String = { isoFormatter.string(from: $0) }
        var itemThemes: [String: [ThemeRef]] = [:]
        for row in source.memberships { itemThemes[row["itemID"], default: []].append(ThemeRef(id: row["id"], title: row["title"])) }
        var entries: [Entry] = []
        var documents: [String: String] = [:]
        var itemPaths: [String: String] = [:]
        for item in items {
            let folder = item.kind == "dictation" ? "dictations" : item.kind + "s"
            let path = "\(folder)/\(dayFormatter.string(from: item.capturedAt))-\(item.sourceID.prefix(8)).md"
            itemPaths[item.id] = path
            entries.append(Entry(path: path, kind: folder, title: item.title, timestamp: iso(item.capturedAt), themes: itemThemes[item.id] ?? [], pinned: item.pinned, image_path: item.kind == "screenshot" ? item.sourcePath : nil))
            var fields = ["id: \(item.sourceID)"]
            if item.kind == "meeting", let meeting = meetings[item.sourceID] {
                let ended: Date? = meeting["endedAt"]
                fields += ["started: \(iso(item.capturedAt))", "ended: \(ended.map(iso) ?? "")", "participants:"]
                let names = participants(meeting, transcript: item.body)
                fields += names.isEmpty ? ["  []"] : names.map { "  - \(scalar($0))" }
                if meeting.columnNames.contains("kind"), let kind: String = meeting["kind"] { fields.append("kind: \(scalar(kind))") }
                if !item.body.isEmpty && item.body.split(whereSeparator: \.isWhitespace).count < 100 { fields.append("low_content: true") }
            } else {
                fields.append("\(["screenshot", "recording"].contains(item.kind) ? "captured" : "created"): \(iso(item.capturedAt))")
            }
            if !item.sourcePath.isEmpty { fields.append("file: \(scalar(item.sourcePath))") }
            if let duration = recordings[item.sourceID], item.kind == "recording" { fields.append("duration_seconds: \(duration)") }
            fields.append("updated: \(iso(item.modifiedAt))")
            var body = item.body
            if item.kind == "meeting" { body = [item.summary, "## Transcript\n\n" + item.body].filter { !$0.isEmpty }.joined(separator: "\n\n") }
            if !item.metadata.isEmpty { body += "\n\n## Capture metadata\n\n" + item.metadata }
            documents[path] = markdown(fields: fields, title: item.title, body: body)
        }
        // Full task evidence, including notes, dates, and completed history.
        // Support databases both before and after the archived-task migration.
        for task in source.tasks {
            let id: String = task["id"], title: String = task["title"], done: Bool = task["done"], created: Date = task["createdAt"]
            let notes: String = task["notes"], source: String = task["source"]
            let due: Date? = task["dueDate"], completed: Date? = task["completedAt"]
            let path = "task-items/\(id).md"
            entries.append(Entry(path: path, kind: "tasks", title: title, timestamp: iso(created), done: done))
            var fields = ["id: \(id)", "created: \(iso(created))", "source: \(scalar(source))", "done: \(done)"]
            if let due { fields.append("due: \(iso(due))") }
            if let completed { fields.append("completed: \(iso(completed))") }
            var body = notes
            if task.columnNames.contains("sourceMeetingID"), let meetingID: String = task["sourceMeetingID"], let sourcePath = itemPaths["meeting-" + meetingID] {
                body += "\n\nSource meeting: \(sourcePath)"
            }
            documents[path] = markdown(fields: fields, title: title, body: body)
        }
        for theme in source.themes {
            let id: String = theme["id"], title: String = theme["title"], pinned: Bool = theme["pinned"]
            let members = items.filter { itemThemes[$0.id]?.contains { $0.id == id } == true }.sorted { $0.capturedAt < $1.capturedAt }
            guard let latest = members.last?.capturedAt else { continue }
            let path = "themes/\(id).md"
            entries.append(Entry(path: path, kind: "themes", title: title, timestamp: iso(latest), pinned: pinned))
            let body = "Saved MyMan Theme · \(members.count) items\n\n" + members.compactMap { item -> String? in
                guard let source = itemPaths[item.id] else { return nil }
                return "- \(iso(item.capturedAt)) · \(item.kind) · \(scalar(item.title)) · \(source)"
            }.joined(separator: "\n")
            documents[path] = markdown(fields: ["id: \(id)", "updated: \(iso(latest))"], title: title, body: body)
        }
        return Snapshot(catalog: Catalog(generated_at: iso(Date()), exports: entries), documents: documents)
    }

    private static func markdown(fields: [String], title: String, body: String) -> String {
        "---\n" + fields.joined(separator: "\n") + "\n---\n\n# \(scalar(title))\n\n\(body)\n"
    }
    private static func scalar(_ value: String) -> String { value.components(separatedBy: .newlines).joined(separator: " ") }

    private struct Participant: Decodable { var name: String; var email: String?; var isOwner: Bool }
    private static func participants(_ row: Row, transcript: String) -> [String] {
        var names = Brain.speakers(in: transcript)
        if row.columnNames.contains("participantsJSON") {
            let json: String = row["participantsJSON"], owner: String = row["ownerName"]
            let people = (try? JSONDecoder().decode([Participant].self, from: Data(json.utf8))) ?? []
            names = names.map { $0 == "You" && !owner.isEmpty ? owner : $0 }
            for person in people {
                names.removeAll { $0 == person.name || $0 == person.name.split(separator: " ").first.map(String.init) }
                names.append(person.name + (person.email.map { " <\($0)>" } ?? ""))
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// Coalesces source and organization changes without blocking capture or UI.
final class BrainAgentExportObserver: TransactionObserver, @unchecked Sendable {
    static let shared = BrainAgentExportObserver()
    private var changed = false // GRDB transaction queue only
    func start() { Database.shared.add(transactionObserver: self); Brain.scheduleAgentExport() }
    func observes(eventsOfKind kind: DatabaseEventKind) -> Bool {
        ["captureItem", "meeting", "task", "captureTheme", "captureThemeMember"].contains(kind.tableName)
    }
    func databaseDidChange(with event: DatabaseEvent) { changed = true }
    func databaseDidCommit(_ db: GRDB.Database) { if changed { changed = false; Brain.scheduleAgentExport() } }
    func databaseDidRollback(_ db: GRDB.Database) { changed = false }
}
