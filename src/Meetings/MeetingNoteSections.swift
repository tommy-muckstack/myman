import Foundation
import NaturalLanguage

enum MeetingNoteSections {
    static func isSubstantive(_ text: String) -> Bool {
        let smallTalk = ["how's your day", "how is your day", "back to school", "your kids", "old are", "same school", "different schools", "offsite next week", "virtually meet", "coming out of today's call"]
        return !smallTalk.contains { text.localizedCaseInsensitiveContains($0) }
            && !MeetingEvidence.isAgendaPrompt(text)
    }

    static func salience(_ text: String) -> Int {
        let cues = ["process", "friction", "staff", "foundation", "signal", "customer", "journey", "partner", "commit", "scale", "decision", "because", "instead", "success", "tension", "speed up"]
        return cues.filter { text.localizedCaseInsensitiveContains($0) }.count * 4
            + Set(MeetingSource.words(text).filter { $0.count > 5 }).count
    }
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        return result
    }

    /// Extractive by construction: quotes are exact source substrings, never
    /// model paraphrases. Rank beliefs/decisions, keeping coverage across time.
    static func quotes(meeting: Meeting, limit: Int = 10, separation: Double = 20) -> String {
        let original = MeetingSource.notesTurns(MeetingSource.parse(meeting.transcript))
        let turns = original + MeetingSource.paragraphs(original)
        var candidates: [(source: MeetingSourceTurn, text: String, score: Int)] = []
        for turn in turns where !MeetingSource.genericSpeaker(turn.speaker) {
            let parts = sentences(turn.text)
            // ASR punctuation can split one thought into several sentences.
            // Offer adjacent exact-source spans as well as single sentences.
            var spans = parts
            for index in parts.indices {
                for count in 2...3 where index + count <= parts.count {
                    let slice = Array(parts[index..<(index + count)])
                    guard let first = turn.text.range(of: slice[0]),
                          let last = turn.text.range(of: slice.last!, range: first.lowerBound..<turn.text.endIndex) else { continue }
                    spans.append(String(turn.text[first.lowerBound..<last.upperBound]))
                }
            }
            for originalSentence in spans {
                let sentence = originalSentence.replacingOccurrences(of: #"(?i)^(?:(?:for a while|a lot of|and so|and|so|um|uh|yeah|like)[, ]+)+"#, with: "", options: .regularExpression)
                    .components(separatedBy: ", which ").first ?? originalSentence
                let words = MeetingSource.words(sentence)
                let completeText = originalSentence.contains(", which ") ? sentence + "." : sentence
                let shortPrinciple = !Set(words).isDisjoint(with: ["need", "should", "strategy", "understanding", "important"])
                guard (8...65).contains(words.count) || (5...7).contains(words.count) && shortPrinciple && quoteScore(sentence) >= 45,
                      !sentence.contains("?"), MeetingEvidence.legible(sentence),
                      isSubstantive(sentence), completeSentence(completeText, minWords: 5), quoteHasSubject(sentence) else { continue }
                let owner = Set([meeting.ownerName, meeting.resolvedOwner, "You"])
                let roleBonus = MeetingInterviewContext.isInterview(meeting.title) && !owner.contains(turn.speaker) ? 12 : 0
                let score = quoteScore(sentence) + roleBonus
                guard quoteScore(sentence) > 0 else { continue }
                let anchor = quoteAnchor(sentence, paragraph: turn, originals: original)
                candidates.append((anchor, sentence, score))
            }
        }
        var selected: [(source: MeetingSourceTurn, text: String, score: Int)] = []
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.source.id < $1.source.id : $0.score > $1.score }) {
            guard !selected.contains(where: { $0.text == candidate.text || abs($0.source.seconds - candidate.source.seconds) < separation }) else { continue }
            selected.append(candidate)
            if selected.count == limit { break }
        }
        let lines = selected.sorted { $0.source.id < $1.source.id }.map { "- “\($0.text)” — \($0.source.speaker) [\($0.source.timestamp)]" }
        return "## Quotes\n\n" + (lines.isEmpty ? "No clear, attributable quotes found." : lines.joined(separator: "\n"))
    }

    static func quoteAnchor(_ quote: String, paragraph: MeetingSourceTurn, originals: [MeetingSourceTurn]) -> MeetingSourceTurn {
        guard let position = paragraph.text.range(of: quote) else { return paragraph }
        let offset = paragraph.text.distance(from: paragraph.text.startIndex, to: position.lowerBound)
        var cursor = paragraph.text.startIndex
        for turn in originals where turn.speaker == paragraph.speaker && turn.id >= paragraph.id {
            guard let range = paragraph.text.range(of: turn.text, range: cursor..<paragraph.text.endIndex) else { continue }
            let end = paragraph.text.distance(from: paragraph.text.startIndex, to: range.upperBound)
            if offset < end { return turn }
            cursor = range.upperBound
        }
        return paragraph
    }

    static func quoteScore(_ sentence: String) -> Int {
        let words = MeetingSource.words(sentence)
        let lower = words.joined(separator: " ")
        let introductions = ["background on myself", "background about myself", "i worked at", "i used to work", "i graduated", "among the actual", "i was thinking about just", "i was wondering", "nice to meet", "thanks for taking", "happy to answer", "i ll put it this way", "i don t know if you", "you know it s not"]
        guard !introductions.contains(where: lower.contains) else { return 0 }
        let beliefs: Set<String> = ["believe", "need", "important", "success", "focus", "decided", "should", "strategy", "want", "feel", "learned"]
        let contrasts = [" but ", " instead ", " rather ", " versus ", " not ", "wasn t", "can t", "don t", "doesn t"]
        let contrast = ["aren t", "isn t", "won t", "couldn t"].contains(where: lower.contains) || contrasts.contains { (" " + lower + " ").contains($0) }
        let strongContrast = ["can t", "cannot", "wasn t", "don t", "doesn t", "not ", "instead", "aren t", "isn t", "won t", "couldn t"].contains { lower.contains($0) }
            || (words.contains("right") && words.contains("wrong"))
        let belief = !Set(words).isDisjoint(with: beliefs)
        let number = words.contains { $0.first?.isNumber == true || ["percent", "hundred", "thousand", "million", "billion", "third", "fourth", "seven", "eight"].contains($0) }
        // Most quotes need eight words. A short, complete principle or contrast
        // can be the point itself; never pad it with surrounding filler.
        guard words.count >= 8 || ((belief || contrast) && words.count >= 5), belief || contrast || number else { return 0 }
        let filler: Set<String> = ["um", "uh", "like", "yeah", "just", "kind", "sort"]
        let repeats = zip(words, words.dropFirst()).filter { $0 == $1 }.count
        let repeatedContent = Dictionary(grouping: words.filter { $0.count >= 5 }, by: { $0 }).values.reduce(0) { $0 + max(0, $1.count - 1) }
        let principle = ["we", "you", "people", "customers", "users", "teams"].contains(words.first ?? "")
        return (belief ? 24 : 0) + (strongContrast ? 24 : (contrast ? 10 : 0)) + (number ? 20 : 0) + (principle ? 10 : 0)
            + min(8, salience(sentence)) + (words.count <= 18 ? 8 : 0)
            - words.filter { filler.contains($0) }.count * 3 - repeats * 6 - repeatedContent * 3
    }

    static func quoteHasSubject(_ sentence: String) -> Bool {
        let words = MeetingSource.words(sentence)
        guard let first = words.first else { return false }
        let fragments: Set<String> = ["and", "or", "but", "because", "which", "among", "for", "from", "with", "related", "instead", "weird", "some", "is"]
        guard !fragments.contains(first),
              sentence.range(of: #"(?i)\b(if|because|when|where|that)\s+\w+\s+\1\b"#, options: .regularExpression) == nil,
              sentence.range(of: #"[a-z]\s+(And|But|Or|So|Because)\b"#, options: .regularExpression) == nil,
              sentence.range(of: #"\.\s+[a-z]"#, options: .regularExpression) == nil else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass]); tagger.string = sentence
        let (tag, _) = tagger.tag(at: sentence.startIndex, unit: .word, scheme: .lexicalClass)
        if tag == .number, words.count > 1, ["we", "you", "they", "i", "it"].contains(words[1]) { return false }
        let spokenSubjects = ["we", "you", "they", "it", "there", "people", "customers", "users", "teams"]
        guard sentence.first?.isUppercase == true || spokenSubjects.contains(first) || tag == .number else { return false }
        return [.pronoun, .noun, .number].contains(tag) || ["there", "that", "this", "the", "a", "an"].contains(first)
    }

    static func completeSentence(_ text: String, minWords: Int = 6) -> Bool {
        let words = MeetingSource.words(text)
        let unfinished: Set<String> = ["and", "but", "or", "um", "uh", "the", "to", "that", "then", "because", "with", "of", "a", "an", "your", "our", "my", "in", "for", "which"]
        return words.count >= minWords && [".", "!"].contains(text.last.map(String.init) ?? "")
            && !unfinished.contains(words.last ?? "")
            && !text.contains("[unclear]") && !text.contains("[inaudible]")
    }

    static func interview(meeting: Meeting) -> String {
        MeetingInterviewAnswers.render(MeetingInterviewAnswers.exchanges(meeting))
            + MeetingInterviewContext.unmatchedQuestions(for: meeting)
    }
}
