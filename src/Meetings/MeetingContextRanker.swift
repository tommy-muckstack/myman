import Foundation
import GRDB

/// Someone on the call, as far as the calendar and the call window know.
struct MeetingContextPerson: Equatable, Hashable, Sendable {
    var name: String
    var email: String?
}

/// Everything the ranker needs for one refresh. Built on the main actor,
/// consumed off it.
struct MeetingContextRequest: Sendable {
    var meetingID: String?
    var startedAt: Date
    var title: String
    var attendees: [MeetingContextPerson]
    var terms: [String]
    /// True for the first pass at meeting start: broader (semantic) search
    /// and the attendees' history, before anyone has said anything.
    var seed: Bool
    /// Cards already on screen or dismissed this meeting.
    var excludedIDs: Set<String> = []
    var now: Date = Date()
}

/// One card in the stream. `id` is the capture item's id so a card is never
/// shown twice in a meeting.
struct MeetingContextCard: Identifiable, Equatable, Sendable {
    enum Basis: String, Sendable { case people, topic, meaning }
    let id: String
    let item: CaptureItem
    let basis: Basis
    /// One short line explaining why it is here: "Last met 3 weeks ago · with Amy".
    let reason: String
    let people: [String]
    let excerpt: String
    let score: Double
}

/// Term extraction and ranking behind one seam so a hosted provider can
/// replace either half later without touching the stream.
protocol MeetingContextProvider: Sendable {
    func terms(in text: String, exclude: Set<String>, limit: Int) -> [String]
    func rank(_ request: MeetingContextRequest, database: DatabaseQueue) throws -> [MeetingContextCard]
}

struct LocalMeetingContextProvider: MeetingContextProvider {
    init() {}
    func terms(in text: String, exclude: Set<String>, limit: Int) -> [String] {
        MeetingContextTerms.salient(in: text, exclude: exclude, limit: limit)
    }
    func rank(_ request: MeetingContextRequest, database: DatabaseQueue) throws -> [MeetingContextCard] {
        try MeetingContextRanker.cards(for: request, database: database)
    }
}

enum MeetingContextRanker {
    struct PastMeeting: Sendable {
        var item: CaptureItem
        var shared: [String]
        var startedAt: Date
    }

    /// Earlier recorded meetings that any of these people were in. Matching
    /// is by email when both sides have one, otherwise by name the way the
    /// live transcript matches speakers. The owner never counts as overlap.
    static func pastMeetings(with people: [MeetingContextPerson], excluding meetingID: String?, before: Date,
                             limit: Int = 25, database: DatabaseQueue) throws -> [PastMeeting] {
        guard !people.isEmpty else { return [] }
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, m.participantsJSON AS participantsJSON, m.startedAt AS meetingStartedAt
                FROM meeting m JOIN captureItem c ON c.id = 'meeting-' || m.id
                WHERE c.excluded = 0 AND m.id != ? AND m.startedAt < ? AND m.participantsJSON != '[]' AND m.participantsJSON != ''
                ORDER BY m.startedAt DESC LIMIT 400
                """, arguments: [meetingID ?? "", before])
        }
        let emails = Set(people.compactMap { $0.email?.lowercased() })
        var results: [PastMeeting] = []
        for row in rows {
            let json: String = row["participantsJSON"] ?? "[]"
            guard let participants = try? JSONDecoder().decode([MeetingParticipant].self, from: Data(json.utf8)) else { continue }
            let shared = participants.filter { participant in
                guard !participant.isOwner else { return false }
                if let email = participant.email?.lowercased(), emails.contains(email) { return true }
                return people.contains { LiveMeetingTranscript.sameName($0.name, participant.name) }
            }.map(\.name)
            guard !shared.isEmpty else { continue }
            results.append(PastMeeting(item: try CaptureItem(row: row), shared: shared, startedAt: row["meetingStartedAt"]))
            if results.count >= limit { break }
        }
        return results
    }

    private struct Candidate {
        var item: CaptureItem
        var matched: [String] = []
        var titleMatch = false
        var people: [String] = []
        var meaning = false
    }

    static func cards(for request: MeetingContextRequest, database: DatabaseQueue, limit: Int = 8) throws -> [MeetingContextCard] {
        var candidates: [String: Candidate] = [:]
        let liveID = request.meetingID.map { "meeting-" + $0 }
        let linkedNotes: Set<String> = try database.read { db in
            guard let meetingID = request.meetingID else { return [] }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM note WHERE meetingID = ?", arguments: [meetingID])
            return Set(ids.map { "note-" + $0 })
        }
        func admit(_ item: CaptureItem) -> Bool {
            if item.excluded || item.id == liveID || linkedNotes.contains(item.id) || request.excludedIDs.contains(item.id) { return false }
            if item.kind == "meeting", item.capturedAt >= request.startedAt { return false }
            if item.capturedAt > request.now { return false }
            return true
        }

        for past in try pastMeetings(with: request.attendees, excluding: request.meetingID, before: request.startedAt, database: database)
        where admit(past.item) {
            candidates[past.item.id, default: Candidate(item: past.item)].people = past.shared
        }
        // The FTS expression ANDs every word, so each term is its own query.
        for term in request.terms.prefix(6) {
            for match in try CaptureIndex.lexical(term, limit: 12, database: database) where admit(match.item) {
                var candidate = candidates[match.item.id] ?? Candidate(item: match.item)
                if !candidate.matched.contains(term) { candidate.matched.append(term) }
                if match.tier == 0 { candidate.titleMatch = true }
                candidates[match.item.id] = candidate
            }
        }
        if request.seed, !request.terms.isEmpty {
            let query = request.terms.prefix(3).joined(separator: " ")
            for match in try CaptureIndex.expanded(query, lexical: [], limit: 10, semantic: true, database: database)
            where admit(match.item) && candidates[match.item.id] == nil {
                var candidate = Candidate(item: match.item)
                candidate.meaning = true
                candidate.matched = match.matchedTerms
                candidates[match.item.id] = candidate
            }
        }

        let properNouns = Set(request.terms.filter { $0.first?.isUppercase == true }.map { $0.lowercased() })
        let cards = candidates.values.map { candidate -> MeetingContextCard in
            let item = candidate.item
            var topic = candidate.matched.reduce(0.0) { $0 + (properNouns.contains($1.lowercased()) ? 1.5 : 1.0) }
            if candidate.titleMatch { topic += 0.5 }
            if candidate.meaning, candidate.matched.isEmpty { topic += 0.75 }
            let people = min(4, Double(candidate.people.count)) * 2.0
            let ageDays = max(0, request.now.timeIntervalSince(item.capturedAt) / 86_400)
            let recency = 1 / (1 + ageDays / 30)
            let kindWeight: Double = switch item.kind {
            case "meeting": 1.0
            case "note", "brainNote": 0.9
            case "recording": 0.6
            case "dictation": 0.5
            default: 0.4
            }
            let score = (topic + people) * kindWeight + recency
            let basis: MeetingContextCard.Basis = !candidate.people.isEmpty ? .people : (candidate.matched.isEmpty ? .meaning : .topic)
            return MeetingContextCard(id: item.id, item: item, basis: basis,
                                      reason: reason(for: candidate, basis: basis, now: request.now),
                                      people: candidate.people, excerpt: excerpt(for: candidate), score: score)
        }
        return Array(cards.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.item.capturedAt > b.item.capturedAt
        }.prefix(limit))
    }

    private static func reason(for candidate: Candidate, basis: MeetingContextCard.Basis, now: Date) -> String {
        switch basis {
        case .people:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let when = formatter.localizedString(for: candidate.item.capturedAt, relativeTo: now)
            let names = candidate.people.prefix(2).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            var line = "Last met " + when
            if !names.isEmpty { line += " · with " + names.joined(separator: " and ") }
            if !candidate.matched.isEmpty { line += " · mentions " + candidate.matched.prefix(2).joined(separator: ", ") }
            return line
        case .topic:
            return "Mentions: " + candidate.matched.prefix(3).joined(separator: ", ")
        case .meaning:
            return "Related meaning"
        }
    }

    private static func excerpt(for candidate: Candidate) -> String {
        let item = candidate.item
        if !candidate.matched.isEmpty {
            let body = item.kind == "meeting" && !item.summary.isEmpty ? item.summary : item.body
            return CaptureText.excerpt(body, query: candidate.matched.joined(separator: " "), length: 160)
        }
        let source = item.summary.isEmpty ? item.body : item.summary
        return String(source.prefix(160)).replacingOccurrences(of: "\n", with: "  ")
    }
}
