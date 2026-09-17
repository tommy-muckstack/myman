import Foundation
import GRDB

/// Extends the existing portable Brain. The database remains authoritative;
/// this catalog contains retrieval metadata, never a second search index.
enum BrainAgentExport {
    struct ThemeRef: Codable, Equatable { var id: String; var title: String }
    struct MeetingRef: Codable { var id: String; var path: String; var association: String }
    struct Entry: Codable {
        var item_id: String? = nil
        var revision: Int? = nil
        var path: String
        var kind: String
        var title: String
        var timestamp: String
        var themes: [ThemeRef] = []
        var pinned: Bool = false
        var done: Bool? = nil
        var image_path: String? = nil
        var captured_local: String? = nil
        var timezone: String? = nil
        var timezone_source: String? = nil
        var app: String? = nil
        var bundle_id: String? = nil
        var window_title: String? = nil
        var url: String? = nil
        var meetings: [MeetingRef]? = nil
        var screenshots: [String]? = nil
        var tags: [ScreenshotIntelligence.Tag]? = nil
        var contains_pii: String? = nil
        var contains_confidential: String? = nil
        var summary: String? = nil
        var thumbnail_path: String? = nil
        var similar_to: String? = nil
        var sequence_id: String? = nil
    }
    struct Catalog: Codable {
        var version = 1
        var generated_at: String
        var exports: [Entry]
    }
    struct Snapshot {
        var catalog: Catalog
        var documents: [String: String]
        var assets: [String: Data] = [:]
    }
    struct Source {
        var items: [CaptureItem]
        var meetings: [String: Row]
        var recordings: [String: Int]
        var memberships: [Row]
        var tasks: [Row]
        var themes: [Row]
        var contexts: [String: ScreenshotContext] = [:]
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
        let contexts = Dictionary(uniqueKeysWithValues: try ScreenshotContext.fetchAll(db).map { ($0.itemID, $0) })
        return Source(items: items, meetings: meetings, recordings: recordings, memberships: memberships, tasks: tasks, themes: themes, contexts: contexts)
    }

    static func snapshot(in db: GRDB.Database) throws -> Snapshot { snapshot(source: try source(in: db)) }

    static func snapshot(source: Source, root: URL = Brain.root) -> Snapshot {
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
            itemPaths[item.id] = "\(folder)/\(dayFormatter.string(from: item.capturedAt))-\(item.sourceID.prefix(8)).md"
        }
        var assets: [String: Data] = [:]
        var screenshotMeetings: [String: [MeetingRef]] = [:]
        var meetingScreenshots: [String: [String]] = [:]
        let shots = items.filter { $0.kind == "screenshot" }.sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
        var similar: [String: String] = [:], sequences: [String: String] = [:]
        var anchors: [CaptureItem] = []
        for shot in shots {
            let context = source.contexts[shot.id]
            for (id, row) in meetings.sorted(by: { $0.key < $1.key }) {
                guard let meetingPath = itemPaths["meeting-" + id] else { continue }
                let start: Date = row["startedAt"], end: Date? = row["endedAt"]
                let explicit = context?.meetingID == id
                let overlaps = end.map { shot.capturedAt >= start && shot.capturedAt < $0 } ?? false
                if explicit || overlaps {
                    screenshotMeetings[shot.id, default: []].append(MeetingRef(id: id, path: meetingPath, association: explicit ? "recorded_during" : "time_overlap"))
                    meetingScreenshots[id, default: []].append(itemPaths[shot.id]!)
                }
            }
            screenshotMeetings[shot.id]?.sort { $0.association == $1.association ? $0.id < $1.id : $0.association == "recorded_during" }
            anchors.removeAll { shot.capturedAt.timeIntervalSince($0.capturedAt) > 120 }
            if let context, let anchor = anchors.first(where: { prior in
                guard let previous = source.contexts[prior.id], context.app.isEmpty || previous.app.isEmpty || context.app == previous.app else { return false }
                return ScreenshotIntelligence.similar(previous.analysis.perceptualHash, context.analysis.perceptualHash)
            }) {
                similar[shot.id] = itemPaths[anchor.id]
                sequences[shot.id] = anchor.sourceID; sequences[anchor.id] = anchor.sourceID
            } else { anchors.append(shot) }
        }
        for item in items {
            let path = itemPaths[item.id]!, folder = item.kind == "dictation" ? "dictations" : item.kind + "s"
            let context = source.contexts[item.id]
            let timezone = context.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone.current
            let local = ISO8601DateFormatter(); local.timeZone = timezone; local.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var entry = Entry(path: path, kind: folder, title: item.title, timestamp: iso(item.capturedAt), themes: itemThemes[item.id] ?? [], pinned: item.pinned, image_path: item.kind == "screenshot" ? item.sourcePath : nil)
            entry.item_id = item.id; entry.revision = item.revision
            entry.captured_local = local.string(from: item.capturedAt); entry.timezone = timezone.identifier
            entry.timezone_source = context?.timezone.isEmpty == false ? "capture" : "export_mac"
            if item.kind == "meeting" { entry.screenshots = meetingScreenshots[item.sourceID] ?? [] }
            if item.kind == "screenshot" {
                let analysis = context?.analysis ?? .init()
                entry.app = context?.app.nilIfEmpty; entry.bundle_id = context?.bundleID.nilIfEmpty
                entry.window_title = context?.windowTitle.nilIfEmpty; entry.url = context?.url.nilIfEmpty
                entry.meetings = screenshotMeetings[item.id] ?? []; entry.tags = analysis.tags
                entry.contains_pii = analysis.contains_pii; entry.contains_confidential = analysis.contains_confidential
                entry.summary = analysis.summary.nilIfEmpty
                entry.similar_to = similar[item.id]; entry.sequence_id = sequences[item.id]
                if let thumbnail = context?.thumbnail, UUID(uuidString: item.sourceID) != nil {
                    let asset = "assets/capture-thumbnails/\(item.sourceID).png"
                    assets[asset] = thumbnail
                    entry.thumbnail_path = root.appendingPathComponent(asset).path
                }
            }
            entries.append(entry)
            var fields = ["id: \(item.sourceID)"]
            if item.kind == "meeting", let meeting = meetings[item.sourceID] {
                let ended: Date? = meeting["endedAt"]
                fields += ["started: \(iso(item.capturedAt))", "ended: \(ended.map(iso) ?? "")", "participants:"]
                let names = participants(meeting, transcript: item.body)
                let owner: String = meeting.columnNames.contains("ownerName") ? meeting["ownerName"] : ""
                // Insert before the participants sequence, shared with direct exports.
                fields.insert(contentsOf: MeetingConversation.metadata(transcript: item.body, summary: item.summary, title: item.title, owner: owner.isEmpty ? NSFullUserName() : owner, started: item.capturedAt, ended: ended, participants: names), at: fields.count - 1)
                fields += names.isEmpty ? ["  []"] : names.map { "  - \(scalar($0))" }
                if meeting.columnNames.contains("kind"), let kind: String = meeting["kind"] { fields.append("kind: \(scalar(kind))") }
                if !item.body.isEmpty && item.body.split(whereSeparator: \.isWhitespace).count < 100 { fields.append("low_content: true") }
            } else {
                fields.append("\(["screenshot", "recording"].contains(item.kind) ? "captured" : "created"): \(iso(item.capturedAt))")
            }
            if !item.sourcePath.isEmpty { fields.append("file: \(scalar(item.sourcePath))") }
            if let duration = recordings[item.sourceID], item.kind == "recording" { fields.append("duration_seconds: \(duration)") }
            fields += ["captured_local: \(entry.captured_local!)", "tz: \(quoted(timezone.identifier))", "timezone_source: \(entry.timezone_source!)"]
            if let screenshots = entry.screenshots { fields.append("screenshots: " + json(screenshots)) }
            if item.kind == "screenshot" {
                if let first = entry.meetings?.first { fields += ["meeting: \(quoted(first.id))", "meeting_path: \(quoted(first.path))"] }
                fields += ["meetings: " + json(entry.meetings ?? []), "tags: " + json(entry.tags ?? [])]
                for (key, value) in [("app", entry.app), ("bundle_id", entry.bundle_id), ("window_title", entry.window_title), ("url", entry.url), ("summary", entry.summary), ("thumbnail", entry.thumbnail_path), ("similar_to", entry.similar_to), ("sequence_id", entry.sequence_id), ("contains_pii", entry.contains_pii), ("contains_confidential", entry.contains_confidential)] {
                    if let value { fields.append("\(key): \(quoted(value))") }
                }
                fields.append("ocr_text: |-")
                fields += item.body.components(separatedBy: .newlines).map { "  " + $0 }
            }
            fields.append("updated: \(iso(item.modifiedAt))")
            var body = item.kind == "screenshot" ? (entry.summary ?? "Screenshot; text recognition may still be processing.") : item.body
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
            let description: String = theme["description"]
            let body = (description.isEmpty ? "" : description + "\n\n") + "Saved MyMan Theme · \(members.count) items\n\n" + members.compactMap { item -> String? in
                guard let source = itemPaths[item.id] else { return nil }
                return "- \(iso(item.capturedAt)) · \(item.kind) · \(scalar(item.title)) · \(source)"
            }.joined(separator: "\n")
            documents[path] = markdown(fields: ["id: \(id)", "updated: \(iso(latest))"], title: title, body: body)
        }
        return Snapshot(catalog: Catalog(generated_at: iso(Date()), exports: entries), documents: documents, assets: assets)
    }

    private static func markdown(fields: [String], title: String, body: String) -> String {
        "---\n" + fields.joined(separator: "\n") + "\n---\n\n# \(scalar(title))\n\n\(body)\n"
    }
    private static func json<T: Encodable>(_ value: T) -> String { (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "null" }
    private static func quoted(_ value: String) -> String { json(value) }
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
        ["captureItem", "captureContext", "meeting", "task", "captureTheme", "captureThemeMember"].contains(kind.tableName)
    }
    func databaseDidChange(with event: DatabaseEvent) { changed = true }
    func databaseDidCommit(_ db: GRDB.Database) { if changed { changed = false; Brain.scheduleAgentExport() } }
    func databaseDidRollback(_ db: GRDB.Database) { changed = false }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
