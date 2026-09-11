import Foundation
import GRDB

enum TaskHygiene {
    static func normalized(_ text: String) -> String {
        MeetingSource.normalized(text)
    }

    /// Meeting tasks have one source: validated, named-owner commitments.
    /// Advice, unanswered requests, and other people's work never enter Tasks.
    static func store(_ actions: [MeetingCommitment], meeting: Meeting, in db: GRDB.Database) throws {
        guard meeting.captureKind == .meeting else { return }
        var existing = try TaskItem.filter(Column("archived") == false).fetchAll(db)
        let sources = Dictionary(uniqueKeysWithValues: MeetingSource.publicTurns(MeetingSource.parse(meeting.transcript)).map { turn in
            (turn.id, MeetingSourceTurn(id: turn.id, speaker: turn.speaker == "You" ? meeting.resolvedOwner : turn.speaker,
                timestamp: turn.timestamp, text: MeetingVocabulary.correct(turn.text, terms: DictationCleanup.userVocabulary()).text))
        })
        var added = 0
        for action in actions where action.owner == meeting.resolvedOwner && !action.isRequest && action.confidence >= 0.93 {
            guard added < 3, MeetingEvidence.commitment(action, sources: sources) != nil else { continue }
            let key = "\(action.sourceID)|\(action.owner)"
            let title = action.task + " — " + action.owner
            guard !existing.contains(where: { ($0.sourceMeetingID == meeting.id && $0.sourceActionKey == key)
                || normalized($0.title) == normalized(title) }) else { continue }
            let timestamp = sources[action.sourceID]?.timestamp ?? ""
            let task = TaskItem(id: UUID().uuidString, title: title, source: "meeting", done: false,
                                createdAt: meeting.startedAt, completedAt: nil,
                                notes: "Owner: \(action.owner)\nMeeting: \(meeting.title) [\(timestamp)]\nEvidence: \(action.quote)",
                                sourceMeetingID: meeting.id, sourceActionKey: key)
            try task.insert(db)
            existing.append(task); added += 1
        }
    }

    static func cleanQuotedTask(_ title: String) -> String? {
        let text = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        let prefixes = ["I'll ", "I will ", "I need to ", "Remind me to "]
        let stripped = prefixes.first(where: { text.lowercased().hasPrefix($0.lowercased()) })
            .map { String(text.dropFirst($0.count)) } ?? text
        let result = stripped.prefix(1).uppercased() + stripped.dropFirst()
        return MeetingEvidence.isTaskTitle(result) ? result : nil
    }
}
