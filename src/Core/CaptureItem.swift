import Foundation
import GRDB

struct CaptureItem: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "captureItem"
    var id: String
    var kind: String
    var sourceID: String
    var rawTitle: String
    var generatedTitle: String
    var userTitle: String
    var body: String
    var summary: String
    var metadata: String
    var sourcePath: String
    var capturedAt: Date
    var modifiedAt: Date
    var pinned: Bool
    var excluded: Bool
    var revision: Int

    var title: String {
        for value in [userTitle, rawTitle, generatedTitle] where !value.isEmpty { return value }
        if kind == "dictation", let line = body.split(separator: "\n").first { return String(line.prefix(80)) }
        return kind.capitalized + " · " + capturedAt.formatted(date: .abbreviated, time: .shortened)
    }
    var icon: MMIcon {
        switch kind {
        case "screenshot": .screenshot
        case "meeting": .calendar
        case "dictation": .voice
        case "recording": .recordScreen
        default: .note
        }
    }
    var text: String { [title, body, summary, metadata].filter { !$0.isEmpty }.joined(separator: "\n") }
    var bodyMatchLabel: String {
        switch kind {
        case "screenshot": "Matched screenshot text"
        case "meeting": "Matched meeting transcript"
        case "dictation": "Matched dictated text"
        case "recording": "Matched recording transcript"
        default: "Matched note text"
        }
    }
    func hit(in db: GRDB.Database) throws -> SearchHit? {
        switch kind {
        case "note": return try Note.fetchOne(db, key: sourceID).map(SearchHit.note)
        case "screenshot": return try Screenshot.fetchOne(db, key: sourceID).map(SearchHit.screenshot)
        case "meeting": return try Meeting.fetchOne(db, key: sourceID).map(SearchHit.meeting)
        case "recording": return try ScreenRecording.fetchOne(db, key: sourceID).map(SearchHit.recording)
        case "dictation": return .dictation(DictationRecord(id: sourceID, text: body, createdAt: capturedAt))
        default: return nil
        }
    }
}

struct CaptureMatch: Identifiable {
    var item: CaptureItem
    var tier: Int
    var score: Double
    var excerpt: String
    var reason: String
    var matchedTerms: [String]
    var id: String { item.id }
}

struct CaptureFilter: Equatable {
    var kind: String = "all"
    var after: Date?
    var before: Date?
    var themeID: String?
    var pinnedOnly = false
    var includeExcluded = false
}

enum CaptureText {
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func excerpt(_ text: String, query: String, length: Int = 220) -> String {
        let terms = [query.replacingOccurrences(of: "\"", with: "")] + words(query)
        let range = terms.lazy.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let start = range.map { text.index($0.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: "  ") + (end < text.endIndex ? "…" : "")
    }
    /// Adjacent transpositions and one edit; used only after indexed exact matches.
    static func near(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count <= 1 { return true }
            return differences.count == 2 && differences[1] == differences[0] + 1 && a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]]
        }
        let short = a.count < b.count ? a : b, long = a.count < b.count ? b : a
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1 }
            else if !skipped { skipped = true; j += 1 }
            else { return false }
        }
        return true
    }
}
