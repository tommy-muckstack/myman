import Foundation
import AVFoundation

struct RecordingTranscript: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var start: Double
        var end: Double
        var text: String
    }
    var version = 1
    var sourceBytes: Int
    var sourceModifiedAt: Date
    var segments: [Segment]
    var text: String { segments.map(\.text).joined(separator: " ") }
    static func url(for movie: URL) -> URL { movie.appendingPathExtension("transcript.json") }
    static func load(for movie: URL) -> Self? {
        guard let data = try? Data(contentsOf: url(for: movie)), data.count <= 20_000_000,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              let attributes = try? URL(fileURLWithPath: movie.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              value.sourceBytes == attributes.fileSize, value.sourceModifiedAt == attributes.contentModificationDate,
              value.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= 604_800 && $0.text.count <= 10_000 }) else { return nil }
        return value
    }
    static func save(_ segments: [Segment], for movie: URL) throws {
        let attributes = try URL(fileURLWithPath: movie.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = attributes.fileSize, let modified = attributes.contentModificationDate else { throw CocoaError(.fileReadUnknown) }
        let value = Self(sourceBytes: bytes, sourceModifiedAt: modified, segments: segments)
        try JSONEncoder().encode(value).write(to: url(for: movie), options: .atomic)
    }
    static func subtitles(_ segments: [Segment], webVTT: Bool) -> String {
        func timestamp(_ time: Double) -> String {
            let ms = max(0, Int((time * 1000).rounded()))
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, webVTT ? "." : ",", ms % 1000)
        }
        return (webVTT ? "WEBVTT\n\n" : "") + segments.enumerated().map { i, segment in
            // Caption text cannot inject timing lines or HTML cue markup.
            let text = segment.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").components(separatedBy: .newlines).joined(separator: " ")
            return "\(i + 1)\n\(timestamp(segment.start)) --> \(timestamp(segment.end))\n\(text)\n"
        }.joined(separator: "\n")
    }
    static func captions(_ words: [Segment]) -> [Segment] {
        var result: [Segment] = [], current: Segment?
        for word in words.sorted(by: { $0.start < $1.start }) {
            if let line = current, word.start - line.end > 0.8 || word.end - line.start > 4.5 || line.text.count + word.text.count > 75 {
                result.append(line); current = nil
            }
            if current == nil { current = word }
            else if var line = current { line.text += " " + word.text; line.end = max(line.end, word.end); current = line }
            if word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") {
                if let line = current { result.append(line) }; current = nil
            }
        }
        if let current { result.append(current) }
        return result
    }
    static func chapters(_ segments: [Segment], minimumGap: Double = 90) -> [Segment] {
        var result: [Segment] = []
        for segment in segments where result.isEmpty || segment.start - (result.last?.start ?? 0) >= minimumGap {
            result.append(.init(start: segment.start, end: segment.end, text: String(segment.text.prefix(80))))
        }
        return result
    }
}

struct RecordingEditList: Codable, Equatable {
    struct Cut: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double
        var end: Double
    }
    var cuts: [Cut] = []
    func keptRanges(duration: Double) throws -> [Cut] {
        guard duration.isFinite, duration > 0, cuts.count <= 500,
              cuts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.001 }) else {
            throw PersonalizationError.invalid("Cut ranges must be inside the recording, with end after start.")
        }
        var cursor = 0.0, kept: [Cut] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if cut.start > cursor { kept.append(.init(start: cursor, end: cut.start)) }
            cursor = max(cursor, min(duration, cut.end))
        }
        if cursor < duration { kept.append(.init(start: cursor, end: duration)) }
        guard !kept.isEmpty else { throw PersonalizationError.invalid("Keep at least one part of the recording.") }
        return kept
    }
    static func mappedTime(_ time: Double, ranges: [Cut]) -> Double? {
        var offset = 0.0
        for range in ranges {
            if time >= range.start && time < range.end { return offset + time - range.start }
            offset += range.end - range.start
        }
        return nil
    }
    static func retime(_ segments: [RecordingTranscript.Segment], ranges: [Cut], offset: Double = 0) -> [RecordingTranscript.Segment] {
        var result: [RecordingTranscript.Segment] = [], cursor = offset
        for range in ranges {
            for segment in segments {
                let start = max(range.start, segment.start), end = min(range.end, segment.end)
                if end > start {
                    result.append(.init(start: cursor + start - range.start, end: cursor + end - range.start, text: segment.text))
                }
            }
            cursor += range.end - range.start
        }
        return result.sorted { $0.start < $1.start }
    }
    static func gapSuggestions(_ words: [RecordingTranscript.Segment], duration: Double) -> [Cut] {
        var cursor = 0.0, gaps: [Cut] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if word.start - cursor > 1.5 { gaps.append(.init(start: cursor + 0.25, end: word.start - 0.25)) }
            cursor = max(cursor, word.end)
        }
        if duration - cursor > 1.5 { gaps.append(.init(start: cursor + 0.25, end: duration)) }
        return gaps
    }
    static func fillerSuggestions(_ words: [RecordingTranscript.Segment]) -> [Cut] {
        words.filter { ["um", "uh", "uhm", "hmm"].contains($0.text.trimmingCharacters(in: .punctuationCharacters).lowercased()) }
            .map { .init(start: $0.start, end: $0.end) }
    }
}
