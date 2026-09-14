import Foundation
import Combine
import GRDB

@MainActor final class MeetingDecisions: ObservableObject {
    static let shared = MeetingDecisions()
    struct Decision: Codable, Identifiable {
        var id: String
        var topic: String
        var text: String
        var sourceID: String
        var sourceRevision: Int
        var quote: String
        var timestamp: String
        var speaker: String
        var capturedAt: Date
        var confirmed: Bool
        var createdBy: String
    }
    @Published private(set) var decisions: [Decision] = []
    private var loadFailed = false
    private let file: URL
    private let lookup: (String) -> CaptureItem?
    init(root: URL? = nil, lookup: @escaping (String) -> CaptureItem? = { CaptureIndex.item($0) }) {
        self.lookup = lookup
        let root = root ?? VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        file = root.appendingPathComponent("MeetingDecisions/decisions.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                decisions = try JSONDecoder().decode([Decision].self, from: Data(contentsOf: file))
            } catch { loadFailed = true }
        }
    }
    func current(_ value: Decision) -> Bool {
        guard let source = lookup(value.sourceID), !source.excluded else { return false }
        return source.revision == value.sourceRevision
    }
    func add(sourceID: String, revision: Int, topic: String, text: String, quote: String, human: Bool = false) throws -> Decision {
        guard let source = lookup(sourceID), source.kind == "meeting", !source.excluded else { throw AgentError("NOT_FOUND", "Choose an available meeting.") }
        guard source.revision == revision else { throw AgentError("EDIT_CONFLICT", "The meeting changed. Read its transcript again.") }
        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, topic.count <= 160, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4000, quote.count <= 4000 else { throw AgentError("INVALID_ARGUMENTS", "Enter a topic, a decision and a supporting quote.") }
        let turns = Dictionary(uniqueKeysWithValues: MeetingSource.parse(source.body).map { ($0.id, $0) })
        guard let turn = MeetingEvidence.source(for: quote, in: turns) else { throw AgentError("EVIDENCE_REQUIRED", "Choose a quote occurring in exactly one transcript turn.") }
        let value = Decision(id: UUID().uuidString, topic: topic, text: text, sourceID: sourceID, sourceRevision: revision, quote: quote, timestamp: turn.timestamp, speaker: turn.speaker, capturedAt: source.capturedAt, confirmed: human, createdBy: human ? "human" : AgentContext.principal.id)
        try persist([value] + decisions)
        return value
    }
    func confirm(_ id: String) throws {
        guard let i = decisions.firstIndex(where: { $0.id == id }), current(decisions[i]) else { throw AgentError("SOURCE_CHANGED", "Read the current meeting and create a fresh decision record.") }
        var next = decisions; next[i].confirmed = true; try persist(next)
    }
    func remove(_ id: String) throws { try persist(decisions.filter { $0.id != id }) }
    func purge(itemID: String?) { do { try persist(decisions.filter { itemID != nil && $0.sourceID != itemID }) } catch { decisions = []; try? FileManager.default.removeItem(at: file) } }
    func followup(ids: [String], relatedIDs: [String]) throws -> String {
        guard (1...20).contains(ids.count), Set(ids).count == ids.count, relatedIDs.count <= 12 else { throw AgentError("INVALID_ARGUMENTS", "Select 1–20 reviewed decisions and at most 12 related captures.") }
        let selected = try ids.map { id -> Decision in
            guard let value = decisions.first(where: { $0.id == id }), value.confirmed, current(value) else { throw AgentError("REVIEW_REQUIRED", "Review each decision against its current meeting before drafting a follow-up.") }
            return value
        }.sorted { $0.capturedAt < $1.capturedAt }
        var lines = ["# Follow-up draft", "", "Review this draft before sharing or assigning work.", ""]
        for value in selected {
            lines += ["## " + value.topic, value.text, "", "> " + value.quote.replacingOccurrences(of: "\n", with: "\n> "), "", "Source: \(value.sourceID) · \(value.capturedAt.formatted()) · \(value.speaker) · \(value.timestamp.isEmpty ? "timing unavailable" : value.timestamp)", ""]
        }
        if !relatedIDs.isEmpty { lines += ["## Selected supporting captures", ""] }
        for id in relatedIDs {
            guard let item = lookup(id), !item.excluded else { throw AgentError("NOT_FOUND", "A selected supporting capture is unavailable.") }
            lines += ["- \(item.title) (\(item.kind), \(item.id))"]
            if item.kind == "screenshot" { lines += ["", "![Selected supporting screenshot](\(URL(fileURLWithPath: item.sourcePath).absoluteString))", ""] }
            else { lines += [String((item.summary.isEmpty ? item.body : item.summary).prefix(1500)), ""] }
        }
        return lines.joined(separator: "\n")
    }
    static func renameSpeaker(in transcript: String, from: String, to: String) throws -> String {
        guard !from.isEmpty, !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, to.count <= 80, !to.contains("\n"), !to.contains("*"), !to.contains(":") else { throw AgentError("INVALID_ARGUMENTS", "Use a plain speaker name.") }
        let pattern = "(?m)^\\*\\*" + NSRegularExpression.escapedPattern(for: from) + "\\*\\*(?=\\s*\\[\\d+:\\d{2}\\]:)"
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = transcript as NSString
        guard regex.numberOfMatches(in: transcript, range: NSRange(location: 0, length: ns.length)) > 0 else { throw AgentError("NOT_FOUND", "No timestamped turns use this speaker label.") }
        return regex.stringByReplacingMatches(in: transcript, range: NSRange(location: 0, length: ns.length), withTemplate: NSRegularExpression.escapedTemplate(for: "**" + to + "**"))
    }
    static func correctSpeaker(source: CaptureItem, from: String, to: String) throws -> CaptureItem {
        guard source.kind == "meeting", !source.excluded else { throw AgentError("NOT_FOUND", "Choose an available meeting.") }
        let updated = try renameSpeaker(in: source.body, from: from, to: to)
        try Database.shared.write { db in
            guard try CaptureItem.fetchOne(db, key: source.id)?.revision == source.revision else { throw AgentError("EDIT_CONFLICT", "The transcript changed; read it again.") }
            try db.execute(sql: "UPDATE meeting SET originalTranscript = CASE WHEN originalTranscript = '' THEN transcript ELSE originalTranscript END, transcript = ?, analysisJSON = '' WHERE id = ?", arguments: [updated, source.sourceID])
        }
        People.learnSpeakerNames(from: updated)
        if let saved = try Database.shared.read({ try Meeting.fetchOne($0, key: source.sourceID) }) {
            Brain.syncMeeting(id: saved.id, title: saved.title, startedAt: saved.startedAt, endedAt: saved.endedAt, summary: saved.summary, transcript: saved.transcript)
        }
        return CaptureIndex.item(source.id) ?? source
    }
    private func persist(_ values: [Decision]) throws {
        guard !loadFailed else { throw AgentError("RECOVERY_UNAVAILABLE", "Existing recovery history could not be read. It has been preserved for recovery.") }
        guard values.count <= 1000 else { throw AgentError("TOO_LARGE", "Remove old decision records before adding more.") }
        let data = try JSONEncoder().encode(values)
        guard data.count <= 8 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Decision history is full.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        decisions = values
    }
}
