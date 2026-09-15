import Foundation

enum MeetingSpeakerHints {
    /// A direct question is one vote for the next distinct speaker within
    /// fifteen seconds. Self-introductions are stronger evidence. Never infer
    /// an identity from overlapping audio or a mere mention of a name.
    static func votes(in turns: [MeetingTurn], names: [String]) -> [String: [String: Int]] {
        var votes: [String: [String: Int]] = [:]
        for (index, turn) in turns.enumerated() {
            let lower = turn.text.lowercased()
            for name in Set(names) where name.count >= 3 {
                let escaped = NSRegularExpression.escapedPattern(for: name.lowercased())
                if turn.speaker.hasPrefix("Speaker "), turn.speaker != "Speaker unclear",
                   lower.range(of: "\\b(i'm|i am|this is|it's)\\s+" + escaped + "\\b", options: .regularExpression) != nil {
                    votes[turn.speaker, default: [:]][name, default: 0] += 3
                }
                let directQuestion = "(?:^|[.!?]\\s*|,\\s*)(?:hey\\s+)?" + escaped + "(?:\\s*[,?]|\\s+(?:what|how|can|could|would|do|did|are|will|have|any|your)\\b)"
                guard lower.range(of: directQuestion, options: .regularExpression) != nil,
                      let next = turns[(index + 1)...].first(where: { $0.speaker != turn.speaker }),
                      next.start >= turn.end - 0.25, next.start - turn.end <= 15,
                      next.speaker.hasPrefix("Speaker "), next.speaker != "Speaker unclear" else { continue }
                votes[next.speaker, default: [:]][name, default: 0] += 1
            }
        }
        return votes
    }

    static func suggestions(in turns: [MeetingTurn], names: [String]) -> [String: String] {
        votes(in: turns, names: names).compactMapValues { tally in
            let ranked = tally.sorted { $0.value > $1.value }
            guard let first = ranked.first, ranked.count == 1 || first.value > ranked[1].value else { return nil }
            return first.key
        }
    }
}
