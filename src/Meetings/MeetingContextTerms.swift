import Foundation
import NaturalLanguage

/// Pulls the words worth searching for out of a stretch of live transcript:
/// names, organisations, places and product-style proper nouns first, then
/// the ordinary words people keep repeating. Pure, so it can run anywhere.
enum MeetingContextTerms {
    private static let properNounPattern = #"\b(?:[A-Z][a-z]+[A-Z][A-Za-z]*|[A-Z]{2,6}|[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,})+)\b"#
    private static let properNounStop: Set<String> = ["the", "this", "that", "yeah", "okay", "yes", "you", "and", "but", "so",
                                                      "ai", "ceo", "ok", "html", "pdf", "thanks", "thank", "hello", "right",
                                                      "sure", "well", "good", "great", "um", "uh"]
    /// Weight of a proper noun relative to one repeated ordinary word.
    private static let properNounWeight = 3

    /// - Parameters:
    ///   - text: the last minute or two of transcript, speaker labels removed.
    ///   - exclude: words that are never topics, such as the attendees' own names.
    ///   - limit: how many terms to return, best first.
    static func salient(in text: String, exclude: Set<String> = [], limit: Int = 8) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        let excluded = Set(exclude.flatMap { CaptureText.words($0) })
        var weights: [String: Int] = [:]
        var display: [String: String] = [:]
        var order: [String: Int] = [:]
        var next = 0
        func add(_ term: String, weight: Int) {
            let key = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespaces)
            guard key.count >= 3, key.rangeOfCharacter(from: .letters) != nil, !excluded.contains(key),
                  !properNounStop.contains(key), !CaptureSignals.stopWords.contains(key),
                  !ConceptThemes.generic.contains(key), !MeetingCallParticipants.uiWords.contains(key) else { return }
            if CaptureText.words(key).contains(where: { excluded.contains($0) }) { return }
            weights[key, default: 0] += weight
            if display[key] == nil { display[key] = term; order[key] = next; next += 1 }
        }

        if let regex = try? NSRegularExpression(pattern: properNounPattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                add(ns.substring(with: match.range), weight: properNounWeight)
            }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [NLTag.personalName, .organizationName, .placeName].contains(tag) {
                add(String(text[range]), weight: properNounWeight)
            }
            return true
        }
        for word in CaptureText.words(text) where word.count >= 4 {
            add(word, weight: 1)
        }
        return weights.keys
            .sorted { a, b in
                if weights[a] != weights[b] { return weights[a]! > weights[b]! }
                return order[a]! < order[b]!
            }
            .prefix(limit)
            .compactMap { display[$0] }
    }
}
