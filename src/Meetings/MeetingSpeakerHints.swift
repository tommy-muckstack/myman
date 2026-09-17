import Foundation

enum MeetingSpeakerHints {
    /// A direct question is one vote for the next distinct speaker within
    /// fifteen seconds. Self-introductions are stronger evidence. Never infer
    /// an identity from overlapping audio or a mere mention of a name.
    static func votes(in turns: [MeetingTurn], names: [String]) -> [String: [String: Int]] {
        let names = Set(names).filter { $0.count >= 3 }.map { (original: $0, lower: $0.lowercased()) }
        guard !names.isEmpty, !turns.isEmpty else { return [:] }
        // Resolve the next distinct voice once, rather than searching the
        // remaining transcript for every name in every turn.
        var nextDistinct = Array<Int?>(repeating: nil, count: turns.count)
        if turns.count > 1 {
            for index in stride(from: turns.count - 2, through: 0, by: -1) {
                nextDistinct[index] = turns[index].speaker == turns[index + 1].speaker
                    ? nextDistinct[index + 1] : index + 1
            }
        }
        var votes: [String: [String: Int]] = [:]
        for (index, turn) in turns.enumerated() {
            if Task.isCancelled { return [:] }
            let selfIntroduction = anonymous(turn.speaker)
            let next = nextDistinct[index].map { turns[$0] }
            let respondent = next.flatMap {
                $0.start >= turn.end - 0.25 && $0.start - turn.end <= 15 && anonymous($0.speaker) ? $0.speaker : nil
            }
            guard selfIntroduction || respondent != nil else { continue }
            let lower = turn.text.lowercased()
            for name in names {
                let evidence = evidence(in: lower, name: name.lower)
                if selfIntroduction, evidence.introduction {
                    votes[turn.speaker, default: [:]][name.original, default: 0] += 3
                }
                if let respondent, evidence.question {
                    votes[respondent, default: [:]][name.original, default: 0] += 1
                }
            }
        }
        return votes
    }

    private static func anonymous(_ speaker: String) -> Bool {
        speaker.hasPrefix("Speaker ") && speaker != "Speaker unclear"
    }

    private static func word(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static let introductions = ["i'm", "i’m", "i am", "this is", "it's", "it’s"]
    private static let questions: Set<String> = ["what", "how", "can", "could", "would", "do", "did", "are", "will", "have", "any", "your"]

    /// Literal name matches with bounded context checks. No per-turn regex
    /// compilation/backtracking, and names containing punctuation stay literal.
    private static func evidence(in text: String, name: String) -> (introduction: Bool, question: Bool) {
        var introduction = false, question = false
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let match = text.range(of: name, options: .literal, range: cursor..<text.endIndex) {
            cursor = match.upperBound
            guard match.upperBound == text.endIndex || !word(text[match.upperBound]) else { continue }
            var before = match.lowerBound
            while before > text.startIndex, text[text.index(before: before)].isWhitespace {
                before = text.index(before: before)
            }
            if before < match.lowerBound {
                let prefix = text[..<before]
                for intro in introductions where prefix.hasSuffix(intro) {
                    let start = text.index(before, offsetBy: -intro.count)
                    if start == text.startIndex || !word(text[text.index(before: start)]) { introduction = true }
                }
                // "Hey Casey, ..." has the same sentence-boundary requirement.
                if prefix.hasSuffix("hey") {
                    before = text.index(before, offsetBy: -3)
                    while before > text.startIndex, text[text.index(before: before)].isWhitespace {
                        before = text.index(before: before)
                    }
                }
            }
            let addressed = before == text.startIndex || ".!?,".contains(text[text.index(before: before)])
            if addressed {
                var after = match.upperBound
                while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
                if after < text.endIndex, ",?".contains(text[after]) {
                    question = true
                } else if after > match.upperBound {
                    let start = after
                    while after < text.endIndex, word(text[after]) { after = text.index(after: after) }
                    question = question || questions.contains(String(text[start..<after]))
                }
            }
            if introduction && question { break }
        }
        return (introduction, question)
    }

    static func suggestions(in turns: [MeetingTurn], names: [String]) -> [String: String] {
        votes(in: turns, names: names).compactMapValues { tally in
            let ranked = tally.sorted { $0.value > $1.value }
            guard let first = ranked.first, ranked.count == 1 || first.value > ranked[1].value else { return nil }
            return first.key
        }
    }
}
