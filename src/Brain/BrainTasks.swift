import Foundation
import GRDB

/// Same contract as calendar: simple task-list questions get a direct database
/// answer, never an inferred list from conversational context.
enum BrainTasks {
    static func isOpenTasksQuestion(_ question: String) -> Bool {
        let text = question.lowercased()
        let asksTasks = text.contains("task") || text.contains("to-do") || text.contains("todo")
        let asksList = ["what", "show", "list", "open", "need to", "due"].contains { text.contains($0) }
        return asksTasks && asksList
    }

    static func openTasksAnswer() -> String {
        let tasks: [TaskItem] = (try? Database.shared.read { db in
            try TaskItem.filter(Column("done") == false)
                .order(Column("dueDate").asc, Column("createdAt").desc).limit(30).fetchAll(db)
        }) ?? []
        guard !tasks.isEmpty else { return "You have no open tasks." }
        let formatter = DateFormatter(); formatter.dateStyle = .medium
        let lines = tasks.map { task in
            let due = task.dueDate.map { " (due \(formatter.string(from: $0)))" } ?? ""
            return "• \(task.title)\(due)"
        }
        return "Your open tasks:\n" + lines.joined(separator: "\n")
    }

    static func snapshotForContext() -> String {
        let tasks: [TaskItem] = (try? Database.shared.read { db in
            try TaskItem.filter(Column("done") == false)
                .order(Column("dueDate").asc, Column("createdAt").desc).limit(20).fetchAll(db)
        }) ?? []
        return tasks.isEmpty ? "OPEN TASKS: none." : "OPEN TASKS:\n" + tasks.map { "• \($0.title)" }.joined(separator: "\n")
    }
}
