import Foundation
import NaturalLanguage

/// Contiguous semantic segmentation. The model names and summarizes segments;
/// it cannot invent their temporal boundaries or skip a closing subject.
enum MeetingTopicSegmentation {
    static func segments(_ turns: [MeetingSourceTurn]) -> [[MeetingSourceTurn]] {
        guard let first = turns.first, let last = turns.last else { return [] }
        let duration = max(1, last.seconds - first.seconds)
        let windowSeconds = max(60, ceil(duration / 120))
        let buckets = Dictionary(grouping: turns) { Int(($0.seconds - first.seconds) / windowSeconds) }
        let windows = buckets.keys.sorted().map { buckets[$0]! }
        guard windows.count >= 4, let embedder = NLEmbedding.sentenceEmbedding(for: .english) else { return windows }
        let vectors = windows.compactMap { window -> [Double]? in
            let text = window.map(\.text).joined(separator: " ").lowercased()
            let tagger = NLTagger(tagSchemes: [.lexicalClass]); tagger.string = text
            let fillers: Set<String> = ["like", "think", "know", "have", "that", "yeah", "just", "kind", "want", "thing", "things", "would", "could", "there", "really", "good", "going", "been", "what", "were", "will"]
            var terms: [String] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                let word = String(text[range])
                if let tag, [NLTag.noun, .adjective, .verb].contains(tag), word.count > 2, !fillers.contains(word) { terms.append(word) }
                return true
            }
            return embedder.vector(for: terms.joined(separator: " ")) ?? embedder.vector(for: text)
        }
        guard vectors.count == windows.count, let dimension = vectors.first?.count else { return windows }
        let n = vectors.count
        let count = min(12, n / 2, max(1, Int((duration / 300).rounded())))
        // Prefix sums make every segment cost O(d), with no cubic scan over
        // transcript text. Max 120 windows bounds work for long recordings.
        var sums = Array(repeating: Array(repeating: 0.0, count: dimension), count: n + 1)
        var norms = Array(repeating: 0.0, count: n + 1)
        for index in 0..<n {
            for d in 0..<dimension { sums[index + 1][d] = sums[index][d] + vectors[index][d] }
            norms[index + 1] = norms[index] + vectors[index].reduce(0) { $0 + $1 * $1 }
        }
        var costs = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n)
        for start in 0..<n {
            for end in (start + 1)...n {
                var norm = 0.0
                for d in 0..<dimension { let delta = sums[end][d] - sums[start][d]; norm += delta * delta }
                costs[start][end] = norms[end] - norms[start] - norm / Double(end - start)
            }
        }
        var dp = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: count + 1)
        var previous = Array(repeating: Array(repeating: 0, count: n + 1), count: count + 1)
        dp[0][0] = 0
        for group in 1...count {
            for end in 2...n {
                for start in 0...(end - 2) {
                    let value = dp[group - 1][start] + costs[start][end]
                    if value < dp[group][end] { dp[group][end] = value; previous[group][end] = start }
                }
            }
        }
        guard dp[count][n].isFinite else { return windows }
        var end = n; var result: [[MeetingSourceTurn]] = []
        for group in stride(from: count, through: 1, by: -1) {
            let start = previous[group][end]
            result.append(windows[start..<end].flatMap { $0 }); end = start
        }
        return result.reversed()
    }
}
