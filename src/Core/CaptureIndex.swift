import Foundation
import GRDB

enum CaptureIndex {
    static func predicate(_ filter: CaptureFilter, alias: String = "c") -> (String, StatementArguments) {
        var clauses = [filter.includeExcluded ? "1" : "\(alias).excluded = 0"]
        var values: [DatabaseValueConvertible?] = []
        if filter.kind != "all" { clauses.append("\(alias).kind = ?"); values.append(filter.kind) }
        if let after = filter.after { clauses.append("\(alias).capturedAt >= ?"); values.append(after) }
        if let before = filter.before { clauses.append("\(alias).capturedAt < ?"); values.append(before) }
        if filter.pinnedOnly { clauses.append("\(alias).pinned = 1") }
        if let theme = filter.themeID {
            clauses.append("\(alias).id IN (SELECT itemID FROM captureThemeMember WHERE themeID = ? AND blocked = 0)")
            values.append(theme)
        }
        return (clauses.joined(separator: " AND "), StatementArguments(values))
    }

    static func history(filter: CaptureFilter = CaptureFilter(), limit: Int = 100, offset: Int = 0,
                        database: DatabaseQueue = Database.shared) throws -> [CaptureItem] {
        let (whereSQL, arguments) = predicate(filter)
        return try database.read { db in
            try CaptureItem.fetchAll(db, sql: "SELECT c.* FROM captureItem c WHERE \(whereSQL) ORDER BY c.capturedAt DESC, c.id LIMIT ? OFFSET ?",
                                     arguments: arguments + [limit, offset])
        }
    }

    static func item(_ id: String, database: DatabaseQueue = Database.shared) -> CaptureItem? {
        try? database.read { try CaptureItem.fetchOne($0, key: id) }
    }

    static func ftsExpression(_ query: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)"|([^\s"]+)"#) else { return nil }
        let ns = query as NSString
        let clauses = regex.matches(in: query, range: NSRange(location: 0, length: ns.length)).flatMap { match -> [String] in
            let phrase = match.range(at: 1).location != NSNotFound
            let text = ns.substring(with: match.range(at: phrase ? 1 : 2))
            let words = CaptureText.words(text)
            if phrase { return words.isEmpty ? [] : ["\"" + words.joined(separator: " ") + "\""] }
            return words.map { "\"\($0)\"*" }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }

    static func lexical(_ query: String, filter: CaptureFilter = CaptureFilter(), limit: Int = 50,
                        database: DatabaseQueue = Database.shared) throws -> [CaptureMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let (whereSQL, arguments) = predicate(filter)
        let items: [CaptureItem] = try database.read { db in
            if let expression = ftsExpression(q) {
                return try CaptureItem.fetchAll(db, sql: """
                    SELECT c.* FROM captureItem c JOIN capture_fts ON capture_fts.rowid = c.rowid
                    WHERE capture_fts MATCH ? AND \(whereSQL)
                    ORDER BY bm25(capture_fts, 8, 6, 10, 1, 1, 1, 1) LIMIT ?
                    """, arguments: [expression] + arguments + [max(200, limit * 4)])
            }
            // Literal punctuation such as a price symbol still has a defined
            // behavior. Bound this uncommon fallback and escape LIKE syntax.
            let literal = q.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
            return try CaptureItem.fetchAll(db, sql: """
                SELECT c.* FROM captureItem c WHERE \(whereSQL)
                  AND (body LIKE ? ESCAPE '!' OR rawTitle LIKE ? ESCAPE '!')
                ORDER BY capturedAt DESC LIMIT ?
                """, arguments: arguments + ["%\(literal)%", "%\(literal)%", limit])
        }
        // Remembered opens only break ties inside
        // a lexical tier. They can never promote meaning above exact text.
        let boosts = try database.read { db -> [String: Double] in
            let clicks = try Row.fetchAll(db, sql: "SELECT hitID,count(*) AS opens FROM searchClick WHERE query = ? GROUP BY hitID", arguments: [q.lowercased()])
            return Dictionary(uniqueKeysWithValues: clicks.map { ($0["hitID"] as String, min(0.15, Double($0["opens"] as Int) * 0.025)) })
        }
        return rank(items.map { item in var result = match(item, query: q); result.score += boosts[item.id] ?? 0; return result }, limit: limit)
    }

    static func expanded(_ query: String, filter: CaptureFilter = CaptureFilter(), lexical: [CaptureMatch],
                         limit: Int = 50, semantic: Bool = true, database: DatabaseQueue = Database.shared) throws -> [CaptureMatch] {
        var results = lexical
        let known = Set(lexical.map(\.id))
        let terms = CaptureText.words(query)
        let (whereSQL, arguments) = predicate(filter)
        if !query.contains("\""), !terms.isEmpty, terms.count <= 10 {
            let vocabulary = try database.read { db in
                try String.fetchAll(db, sql: "SELECT term FROM capture_vocab ORDER BY doc DESC LIMIT 20000")
            }
            var variants: [String] = []
            for term in terms {
                if Task.isCancelled { return rank(results, limit: limit) }
                let near = vocabulary.lazy.filter { abs($0.count - term.count) <= 1 && CaptureText.near(term, $0) }.prefix(8)
                variants.append("(" + (["\"\(term)\"*"] + near.map { "\"\($0)\"" }).joined(separator: " OR ") + ")")
            }
            let fuzzy: [CaptureItem] = try database.read { db in
                return try CaptureItem.fetchAll(db, sql: """
                    SELECT c.* FROM captureItem c JOIN capture_fts ON capture_fts.rowid = c.rowid
                    WHERE capture_fts MATCH ? AND \(whereSQL) ORDER BY rank LIMIT ?
                    """, arguments: [variants.joined(separator: " AND ")] + arguments + [limit])
            }
            for item in fuzzy where !known.contains(item.id) {
                let matched = Array(Set(CaptureText.words(item.text).filter { word in terms.contains { CaptureText.near($0, word) || word.hasPrefix($0) } })).sorted()
                var result = match(item, query: matched.joined(separator: " "))
                result.tier = 3
                result.reason = "Similar spelling · " + result.reason.replacingOccurrences(of: "Matched ", with: "")
                result.matchedTerms = matched
                results.append(result)
            }
        }
        // A named Theme supplies context only when the query actually mentions
        // it. No foreground-activity monitoring or inferred autonomous intent.
        for theme in try ThemeStore.list(database: database) {
            let nameTerms = CaptureText.words(theme.title)
            guard nameTerms.count >= 2, nameTerms.allSatisfy({ terms.contains($0) }), filter.themeID == nil || filter.themeID == theme.id else { continue }
            var themed = filter; themed.themeID = theme.id
            for item in try history(filter: themed, limit: limit, database: database) {
                results.append(CaptureMatch(item: item, tier: 3, score: 0, excerpt: CaptureText.excerpt(item.body, query: query), reason: "Related to \(theme.title)", matchedTerms: terms))
            }
        }
        if semantic, !query.contains("\""), let embedding = SearchService.embedding(for: query) {
            let vector = SearchService.decodedVector(id: "query", blob: embedding)
            let chunks = try database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT chunk.itemID, chunk.text, chunk.field, chunk.embedding FROM captureChunk chunk
                    JOIN captureItem c ON c.id = chunk.itemID WHERE \(whereSQL) AND chunk.embedding IS NOT NULL
                    """, arguments: arguments)
            }
            // Release SQLite before vector arithmetic so lexical searches and
            // captures never queue behind the semantic scan.
            var best: [String: (String, String, Float)] = [:]
            for row in chunks {
                if Task.isCancelled { break }
                let id: String = row["itemID"], blob: Data = row["embedding"]
                let similarity = SearchService.cosine(vector, SearchService.decodedVector(id: id, blob: blob))
                if similarity > 0.58, similarity > (best[id]?.2 ?? 0) { best[id] = (row["text"], row["field"], similarity) }
            }
            let scores = best.map { ($0.key, $0.value.0, $0.value.1, $0.value.2) }.sorted { $0.3 > $1.3 }.prefix(limit)
            for (id, text, field, score) in scores {
                guard let item = item(id, database: database), !item.excluded else { continue }
                results.append(CaptureMatch(item: item, tier: 4, score: Double(score), excerpt: CaptureText.excerpt(text, query: query), reason: "Related meaning · \(field)", matchedTerms: terms))
            }
        }
        return rank(results, limit: limit)
    }

    static func match(_ item: CaptureItem, query: String) -> CaptureMatch {
        let literal = query.replacingOccurrences(of: "\"", with: "")
        func contains(_ text: String) -> Bool {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let term = literal.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term).replacingOccurrences(of: " ", with: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            return folded.range(of: pattern, options: .regularExpression) != nil
        }
        let fields = [(item.body, item.bodyMatchLabel), (item.summary, "Matched meeting notes"),
                      (item.metadata, "Matched capture metadata"), (item.sourcePath, "Matched filename")]
        let titleMatch = contains(item.title)
        let exact = fields.first { contains($0.0) }
        let termMatch = fields.first { field in CaptureText.words(query).contains { field.0.localizedCaseInsensitiveContains($0) } }
        let field = exact ?? termMatch ?? (item.body, item.bodyMatchLabel)
        let age = max(0, -item.capturedAt.timeIntervalSinceNow / 86400)
        return CaptureMatch(item: item, tier: titleMatch ? 0 : (exact == nil ? 2 : 1),
                            score: (item.title.localizedCaseInsensitiveCompare(literal) == .orderedSame ? 1 : 0) + (item.pinned ? 0.3 : 0) + 0.1 / (1 + age),
                            excerpt: CaptureText.excerpt(field.0.isEmpty ? item.title : field.0, query: query),
                            reason: titleMatch ? "Matched title" : field.1, matchedTerms: CaptureText.words(query))
    }

    static func rank(_ results: [CaptureMatch], limit: Int) -> [CaptureMatch] {
        var seen = Set<String>()
        return Array(results.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.capturedAt != $1.item.capturedAt { return $0.item.capturedAt > $1.item.capturedAt }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}
