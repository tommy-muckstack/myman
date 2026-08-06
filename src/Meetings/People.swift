import EventKit
import Foundation
import GRDB

// The teammate map: every recorded meeting's calendar attendees accumulate
// here, so the brain knows WHO you work with — names, emails, how often and
// how recently you meet. Synced to ~/MyManBrain/people.md (agent-readable)
// and fed into the dictation vocabulary so "Whitfield" stops transcribing
// as "Whatfield".

struct Person: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "person"
    var id: String
    var name: String
    var email: String?
    var meetCount: Int
    var firstMetAt: Date
    var lastMetAt: Date
}

enum People {
    /// Learns only names a person explicitly placed in a transcript speaker
    /// label (for example `**Snehith** [12:04]:`). This is per-machine data;
    /// it never changes the bundled vocabulary for other My Man users.
    static func learnSpeakerNames(from transcript: String) {
        let pattern = #"\*\*([^*\n]{2,80})\*\*\s*\[\d+:\d{2}\]:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(transcript.startIndex..., in: transcript)
        let ignored = Set(["you", "them", "others", "speaker 1", "speaker 2", "speaker 3"])
        let names = Set(regex.matches(in: transcript, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: transcript) else { return nil }
            let name = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2, !ignored.contains(name.lowercased()) else { return nil }
            return name
        })
        guard !names.isEmpty else { return }
        try? Database.shared.write { db in
            for name in names {
                guard try Person.filter(Column("name") == name).fetchOne(db) == nil else { continue }
                try Person(id: UUID().uuidString, name: name, email: nil,
                           meetCount: 1, firstMetAt: Date(), lastMetAt: Date()).insert(db)
            }
        }
        syncBrain()
    }

    /// Record that a meeting happened with these attendees (the current
    /// user excluded upstream). Upserts by email when present, else name.
    static func noteAttendees(_ attendees: [(name: String, email: String?)]) {
        guard !attendees.isEmpty else { return }
        let now = Date()
        try? Database.shared.write { db in
            for attendee in attendees {
                let name = attendee.name.trimmingCharacters(in: .whitespaces)
                guard name.count > 1 else { continue }
                let existing: Person?
                if let email = attendee.email?.lowercased() {
                    existing = try Person.filter(Column("email") == email).fetchOne(db)
                        ?? (try Person.filter(Column("name") == name).fetchOne(db))
                } else {
                    existing = try Person.filter(Column("name") == name).fetchOne(db)
                }
                if var person = existing {
                    person.meetCount += 1
                    person.lastMetAt = now
                    if person.email == nil { person.email = attendee.email?.lowercased() }
                    // Prefer the fuller name variant ("James Whitfield" over "James").
                    if name.count > person.name.count { person.name = name }
                    try person.update(db)
                } else {
                    try Person(id: UUID().uuidString, name: name,
                               email: attendee.email?.lowercased(),
                               meetCount: 1, firstMetAt: now, lastMetAt: now).insert(db)
                }
            }
        }
        syncBrain()
    }

    /// Every known person, most-met first.
    static func all() -> [Person] {
        (try? Database.shared.read { db in
            try Person.order(Column("meetCount").desc, Column("lastMetAt").desc).fetchAll(db)
        }) ?? []
    }

    /// Name words + email-domain tokens for the dictation vocabulary —
    /// exactly the proper nouns ASR keeps guessing wrong.
    static func vocabularyTerms() -> [String] {
        var terms: Set<String> = []
        for person in all() {
            for word in person.name.split(separator: " ") where word.count >= 3 {
                terms.insert(String(word))
            }
            if let email = person.email,
               let domain = email.split(separator: "@").last?.split(separator: ".").first,
               domain.count >= 4, !["gmail", "icloud", "yahoo", "outlook", "hotmail"].contains(String(domain)) {
                terms.insert(String(domain).capitalized)
            }
        }
        return Array(terms)
    }

    private static func syncBrain() {
        var content = "# People\n\nTeammates learned from recorded meetings, most-met first.\n\n"
        for person in all() {
            let email = person.email.map { " — \($0)" } ?? ""
            content += "- **\(person.name)**\(email) — \(person.meetCount) meeting\(person.meetCount == 1 ? "" : "s"), last \(person.lastMetAt.formatted(date: .abbreviated, time: .omitted))\n"
        }
        Brain.syncPeople(content)
    }

    /// Attendees of the calendar event happening right now (±10 min), the
    /// current user excluded.
    static func currentEventAttendees() -> [(name: String, email: String?)] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(600), calendars: nil)
        guard let event = store.events(matching: predicate)
            .filter({ !$0.isAllDay && $0.startDate <= now.addingTimeInterval(600) })
            .sorted(by: { $0.startDate > $1.startDate })
            .first else { return [] }
        return (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap { participant in
                let email = participant.url.absoluteString.hasPrefix("mailto:")
                    ? String(participant.url.absoluteString.dropFirst("mailto:".count))
                    : nil
                let name = participant.name ?? email?.split(separator: "@").first.map(String.init)
                guard let name, !name.isEmpty else { return nil }
                return (name, email)
            }
    }
}
