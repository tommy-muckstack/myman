import Foundation

/// Chapter markers for a recording, from its transcript. A chapter starts after a real pause in speech,
/// the longest pauses win, and no chapter is shorter than `minimumLength`. Titles are the opening words of
/// each section. No model is used, so the result is the same every time for the same transcript.
enum RecordingChapters {
    struct Chapter: Equatable {
        var startMs: Int
        var title: String
    }

    static let maximumChapters = 8
    static let minimumPause = 4.0
    static let minimumLength = 20.0
    static let titleWords = 6

    static func make(from segments: [RecordingTranscript.Segment]) -> [Chapter] {
        let ordered = segments.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return [] }

        // Each pause between speech is a candidate boundary at the start of the next segment.
        var candidates: [(time: Double, pause: Double)] = []
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let pause = next.start - previous.end
            if pause >= minimumPause { candidates.append((next.start, pause)) }
        }
        var starts: [Double] = [0]
        for candidate in candidates.sorted(by: { $0.pause > $1.pause }) where starts.count < maximumChapters {
            // Keep chapters at least `minimumLength` apart, measured from the start of the recording and from each other.
            if starts.allSatisfy({ abs($0 - candidate.time) >= minimumLength }) && candidate.time >= minimumLength {
                starts.append(candidate.time)
            }
        }
        starts.sort()

        return starts.map { start in
            let opening = ordered.first { $0.start >= start - 0.001 } ?? first
            return Chapter(startMs: Int((start * 1000).rounded()), title: title(for: opening.text, index: starts.firstIndex(of: start) ?? 0))
        }
    }

    static func title(for text: String, index: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(titleWords).map(String.init)
        let joined = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return joined.isEmpty ? "Part \(index + 1)" : joined
    }
}
