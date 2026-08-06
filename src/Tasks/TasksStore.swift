import Foundation
import GRDB

struct TaskItem: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task"
    var id: String
    var title: String
    var source: String // meeting | note | dictation | manual
    var done: Bool
    var createdAt: Date
    var completedAt: Date?
    var notes: String = ""
    var dueDate: Date?
}

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    @Published private(set) var openTasks: [TaskItem] = []

    private init() {
        refresh()
    }

    func refresh() {
        openTasks = (try? Database.shared.read { db in
            try TaskItem
                .filter(Column("done") == false)
                .order(Column("createdAt").desc)
                .limit(30)
                .fetchAll(db)
        }) ?? []
        syncBrain()
    }

    private func syncBrain() {
        let done = (try? Database.shared.read { db in
            try TaskItem.filter(Column("done") == true)
                .order(Column("completedAt").desc).limit(100).fetchAll(db)
        }) ?? []
        Brain.syncTasks(
            open: openTasks.map { ($0.title, $0.source, $0.createdAt) },
            done: done.map { ($0.title, $0.source, $0.completedAt) }
        )
    }

    /// Insert extracted tasks, skipping near-duplicates of open ones.
    /// Returns how many were actually added.
    @discardableResult
    func addExtracted(_ titles: [String], source: String) -> Int {
        let existing = Set(openTasks.map { Self.normalize($0.title) })
        var added = 0
        for title in titles {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 3, !existing.contains(Self.normalize(trimmed)) else { continue }
            let task = TaskItem(id: UUID().uuidString, title: trimmed, source: source,
                                done: false, createdAt: Date(), completedAt: nil)
            try? Database.shared.write { try task.insert($0) }
            Analytics.track("task_created", ["source": source])
            added += 1
        }
        if added > 0 { refresh() }
        return added
    }

    /// Manual creation from the composer.
    func add(title: String, notes: String, dueDate: Date?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TaskItem(id: UUID().uuidString, title: trimmed, source: "manual",
                            done: false, createdAt: Date(), completedAt: nil,
                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                            dueDate: dueDate)
        try? Database.shared.write { try task.insert($0) }
        Analytics.track("task_created", ["source": "manual", "has_due": dueDate != nil])
        refresh()
    }

    func update(_ task: TaskItem, title: String, notes: String, dueDate: Date?) {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.dueDate = dueDate
        guard !updated.title.isEmpty else { return }
        try? Database.shared.write { try updated.update($0) }
        refresh()
    }

    func toggle(_ task: TaskItem) {
        var updated = task
        updated.done.toggle()
        updated.completedAt = updated.done ? Date() : nil
        try? Database.shared.write { try updated.update($0) }
        if updated.done {
            Analytics.track("task_completed", ["source": task.source])
        }
        refresh()
    }

    func delete(_ task: TaskItem) {
        _ = try? Database.shared.write { try TaskItem.deleteOne($0, key: task.id) }
        refresh()
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
    }
}
