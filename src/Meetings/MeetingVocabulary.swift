import Foundation
import GRDB
import NaturalLanguage

enum MeetingVocabulary {
    struct Correction { let text: String; let corrections: [String] }

    /// Product and tool names that speech recognizers reliably mangle
    /// ("Amplitune", "Jupiter", "Snow flake"). Applied to meeting transcripts
    /// only, through the same fuzzy restore dictation uses, which needs a
    /// close spelling match — never a global word swap.
    static let commonTerms: [String] = [
        "Amplitude", "Mixpanel", "PostHog", "Datadog", "Snowflake", "Databricks", "BigQuery", "Redshift",
        "Looker", "Tableau", "Jupyter", "Kubernetes", "Terraform", "Postgres", "GraphQL", "TypeScript",
        "Salesforce", "HubSpot", "Zendesk", "Intercom", "Zapier", "Airtable", "Notion", "Figma", "GitHub",
        "GitLab", "Jira", "Confluence", "Linear", "Asana", "Webflow", "Vercel", "Supabase", "Firebase",
        "Shopify", "Stripe", "Segment", "Braze", "Iterable", "Marketo", "Anthropic", "Claude Code",
        "OpenAI", "ChatGPT", "Copilot", "Gemini", "Cursor", "Windsurf", "Granola", "TestFlight", "Xcode",
        "Sentry", "PagerDuty", "Grafana", "Prometheus", "Splunk", "Okta", "Auth0", "Twilio", "SendGrid",
        "Metabase", "dbt", "Airflow", "Kafka", "Redis", "MongoDB", "DynamoDB", "Lambda", "Cloudflare",
        "Netlify", "Heroku", "Docker", "Ansible", "Puppet", "Elasticsearch", "Algolia", "LaunchDarkly",
        "Statsig", "Optimizely", "FullStory", "Hotjar", "Pendo", "Appcues", "WalkMe", "Gong", "Chorus",
    ]

    /// Capitalized words in a title that look like names, products or
    /// companies — not the ordinary words around them.
    static func properNouns(in title: String) -> [String] {
        let stop: Set<String> = ["the", "and", "with", "for", "user", "research", "meeting", "call", "sync", "weekly",
                                 "monthly", "daily", "standup", "review", "planning", "product", "marketing", "design",
                                 "engineering", "sales", "team", "check", "interview", "intro", "demo", "kickoff", "office",
                                 "hours", "discussion", "chat", "catch", "follow", "update", "session", "workshop", "prep"]
        var seen = Set<String>()
        var result: [String] = []
        for token in title.split(whereSeparator: { $0.isWhitespace || "|-–—:/,()[]".contains($0) }) {
            let word = String(token).trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 3, word.first?.isUppercase == true, word.allSatisfy({ $0.isLetter || $0 == "'" }),
                  !stop.contains(word.lowercased()), word != word.uppercased() || word.count <= 5 else { continue }
            if seen.insert(word.lowercased()).inserted { result.append(word) }
        }
        return result
    }

    /// Approved vocabulary is applied only to derived input. Never mutate the
    /// captured transcript. Explicit aliases are useful for a reviewed repair;
    /// ambiguous everyday words are not bundled as global substitutions.
    static func correct(_ text: String, terms: [String], aliases: [String: String] = [:]) -> Correction {
        var value = text
        var applied: [String] = []
        for (alias, canonical) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: alias) + "(?![\\p{L}\\p{N}])") else { continue }
            let range = NSRange(value.startIndex..., in: value)
            if regex.firstMatch(in: value, range: range) != nil {
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: canonical))
                applied.append("\(alias) → \(canonical)")
            }
        }
        // Share the dictation spelling rules, including multiword names, but
        // retain an audit for each actual replacement in derived material.
        value = DictationCleanup.applyVocabulary(value, terms: terms) { original, replacement in
            applied.append("\(original) → \(replacement)")
        }
        return Correction(text: value, corrections: applied)
    }

    static func record(_ meeting: Meeting, in db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM vocabularyMention WHERE meetingID = ?", arguments: [meeting.id])
        let text = MeetingSource.publicTurns(MeetingSource.parse(meeting.transcript)).map(\.text).joined(separator: "\n")
        let pattern = #"\b(?:[A-Z][a-z]+[A-Z][A-Za-z]*|[A-Z]{2,6}|[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,})+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        var terms = Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [NLTag.personalName, .organizationName, .placeName].contains(tag) { terms.insert(String(text[range])) }
            return true
        }
        for person in meeting.participants where !person.isOwner && !person.name.contains("@") { terms.insert(person.name) }
        let stop: Set<String> = ["The", "This", "That", "Yeah", "Okay", "Yes", "You", "And", "But", "So", "AI", "CEO", "OK", "HTML", "PDF"]
        for term in terms where term.count <= 60 && !stop.contains(term) {
            try db.execute(sql: "INSERT OR IGNORE INTO vocabularyMention (term, meetingID) VALUES (?, ?)", arguments: [term, meeting.id])
        }
    }

    static func suggestions(in database: DatabaseQueue = Database.shared) -> [String] {
        (try? database.read { db in
            try String.fetchAll(db, sql: """
                SELECT term FROM vocabularyMention
                WHERE term NOT IN (SELECT term FROM vocabularyDecision)
                GROUP BY term COLLATE NOCASE HAVING count(DISTINCT meetingID) >= 2
                ORDER BY count(DISTINCT meetingID) DESC, term LIMIT 12
                """)
        }) ?? []
    }

    static func refreshSuggestions(in database: DatabaseQueue = Database.shared) async -> [String] {
        await Task.detached(priority: .utility) {
            // Incremental backfill; re-read each row inside its write so a
            // concurrent edit/deletion cannot resurrect stale mentions.
            let ids = (try? database.read { try String.fetchAll($0, sql: "SELECT id FROM meeting WHERE transcript != ''") }) ?? []
            for id in ids {
                guard !Task.isCancelled else { return [] }
                try? database.write { db in
                    if let meeting = try Meeting.fetchOne(db, key: id) { try record(meeting, in: db) }
                }
            }
            let accepted = Set(DictationCleanup.userVocabulary().map { $0.lowercased() })
            return suggestions(in: database).filter { !accepted.contains($0.lowercased()) }
        }.value
    }

    static func decide(_ term: String, accept: Bool) {
        try? Database.shared.write { try $0.execute(sql: "INSERT OR REPLACE INTO vocabularyDecision (term, accepted) VALUES (?, ?)", arguments: [term, accept]) }
        if accept { DictationCleanup.setUserVocabulary(DictationCleanup.userVocabulary() + [term]) }
    }
}
