import Foundation
import NaturalLanguage
import GRDB

/// Names scoped to the invite's external domains. Products and a user's global
/// dictation vocabulary never participate in meeting spelling repair.
enum MeetingPeopleContext {
    static func domains(_ meeting: Meeting) -> Set<String> {
        let consumer: Set<String> = ["gmail.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com", "me.com"]
        return Set(meeting.participants.filter { !$0.isOwner }.compactMap { $0.email?.lowercased().split(separator: "@").last.map(String.init) })
            .subtracting(consumer)
    }

    static func names(for meeting: Meeting, database: DatabaseQueue = Database.shared,
                      folders: [String: String]? = nil) -> [String] {
        let scope = domains(meeting)
        var names = Set(meeting.participants.map(\.name))
        var corroborated: [String: Int] = [:]
        let prior = (try? database.read { try Meeting.filter(Column("id") != meeting.id).order(Column("startedAt").desc).limit(200).fetchAll($0) }) ?? []
        for other in prior where !domains(other).isDisjoint(with: scope) {
            names.formUnion(other.participants.map(\.name))
            for name in personNames(in: other.transcript) { corroborated[name, default: 0] += 1 }
        }
        for document in MeetingCompanyContext.documents(for: meeting, folders: folders) {
            for name in personNames(in: document.text) { corroborated[name, default: 0] += 1 }
        }
        names.formUnion(corroborated.filter { $0.value >= 2 }.map(\.key))
        let blocked = Set(MeetingVocabulary.commonTerms.map { $0.lowercased() })
        return Set(names.flatMap { $0.split(separator: " ").map(String.init) })
            .filter { $0.count >= 4 && $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter)
                && !blocked.contains($0.lowercased()) }.sorted()
    }

    static func personNames(in text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        var names = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName { names.insert(String(text[range])) }; return true
        }
        // Explicit people entries also cover names unknown to Apple's tagger.
        let pattern = #"(?m)^[-*] \*\*([\p{Lu}][\p{L}]{3,})\*\*\s*(?:\.\.|[—–:-])\s*(?:building|owns|engineer|founder|CEO|product|design|leads|runs)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        return names
    }

    static func correct(_ transcript: String, names: [String]) -> MeetingVocabulary.Correction {
        guard !names.isEmpty, let regex = try? NSRegularExpression(pattern: #"\b[\p{Lu}][\p{Ll}]{3,}\b"#) else {
            return .init(text: transcript, corrections: [])
        }
        // A capital alone is insufficient: the candidate must occupy a person
        // reference (talk to NAME, ask NAME, NAME's …), never ordinary prose.
        let personalContext = #"(?i)(?:talk(?:ing)? to|speak to|ask|with|from|to|by)\s+$"#
        var text = transcript; var audit: [String] = []
        for match in regex.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)).reversed() {
            guard let range = Range(match.range, in: transcript) else { continue }
            let token = String(transcript[range])
            guard !names.contains(token) else { continue }
            let prefix = String(transcript[..<range.lowerBound].suffix(30))
            guard prefix.range(of: personalContext, options: .regularExpression) != nil else { continue }
            let word = MeetingSource.normalized(token)
            let tagger = NLTagger(tagSchemes: [.lexicalClass]); tagger.string = token.lowercased()
            let (tag, _) = tagger.tag(at: token.lowercased().startIndex, unit: .word, scheme: .lexicalClass)
            // Common English verbs, pronouns, adjectives, and adverbs are never
            // repaired, even when someone capitalized them in the source.
            if let tag, [NLTag.verb, .pronoun, .adjective, .adverb, .determiner, .preposition, .conjunction].contains(tag) { continue }
            let candidates = names.filter { name in
                let canonical = MeetingSource.normalized(name)
                guard canonical.prefix(2) == word.prefix(2), abs(canonical.count - word.count) <= 1 else { return false }
                return DictationCleanup.editDistance(word, canonical) <= 2
                    || (word.count >= 6 && canonical.count >= 6 && DictationCleanup.editDistance(phonetic(word), phonetic(canonical)) <= 1)
            }
            guard candidates.count == 1 else { continue }
            if let current = Range(match.range, in: text) {
                text.replaceSubrange(current, with: candidates[0]); audit.append("\(token) → \(candidates[0])")
            }
        }
        return .init(text: text, corrections: audit.reversed())
    }

    private static func phonetic(_ word: String) -> String {
        word.replacingOccurrences(of: "k", with: "g").filter { !"aeiouy".contains($0) }
    }
}
