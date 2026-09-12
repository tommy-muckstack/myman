import Foundation
import GRDB

enum AgentSearch {
    static func run(_ args: [String: Any], database: DatabaseQueue = Database.shared, semanticEnabled: Bool) throws -> [String: Any] {
        let query = args["query"] as! String
        var filter = CaptureFilter()
        let kind = args["kind"] as? String ?? "all"
        filter.kind = ["screenshots":"screenshot", "meetings":"meeting", "dictations":"dictation", "recordings":"recording", "notes":"note"][kind] ?? kind
        func date(_ key: String) throws -> Date? {
            guard let text = args[key] as? String else { return nil }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let value = f.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw AgentError("INVALID_ARGUMENTS", "\(key) must be ISO 8601 with a timezone.") }
            return value
        }
        filter.after = try date("after"); filter.before = try date("before")
        if let after = filter.after, let before = filter.before, after >= before { throw AgentError("INVALID_ARGUMENTS", "before must be after after.") }
        filter.pinnedOnly = args["pinned_only"] as? Bool ?? false
        if let theme = args["theme"] as? String {
            let candidates = try ThemeStore.list(database: database).filter { $0.id == theme || $0.title.localizedCaseInsensitiveCompare(theme) == .orderedSame }
            guard candidates.count == 1 else { throw AgentError("AMBIGUOUS_THEME", "Use a theme ID from theme list.", details: ["candidates": candidates.map { ["id": $0.id, "title": $0.title] }]) }
            filter.themeID = candidates[0].id
        }
        let resolved = CaptureQuery.resolve(query, filter: filter)
        let limitValue = args["limit"] as? Double ?? 30, offsetValue = args["offset"] as? Double ?? 0
        guard limitValue.rounded() == limitValue, offsetValue.rounded() == offsetValue else { throw AgentError("INVALID_ARGUMENTS", "limit and offset must be integers.") }
        let limit = Int(limitValue), offset = Int(offsetValue), cap = 1000
        let lexical = try CaptureIndex.lexical(resolved.text, filter: resolved.filter, limit: cap, database: database)
        let useSemantic = semanticEnabled && (args["semantic"] as? Bool ?? true) && !(args["lexical_only"] as? Bool ?? false) && !resolved.text.contains("\"")
        let matches: [CaptureMatch]
        if resolved.text.isEmpty { matches = try CaptureIndex.history(filter: resolved.filter, limit: cap, database: database).map { CaptureIndex.match($0, query: "") } }
        else if args["lexical_only"] as? Bool == true { matches = lexical }
        else { matches = try CaptureIndex.expanded(resolved.text, filter: resolved.filter, lexical: lexical, limit: cap, semantic: useSemantic, database: database) }
        let results = matches.dropFirst(offset).prefix(limit).map { match -> [String: Any] in
            ["id": match.id, "kind": match.item.kind, "title": match.item.title, "captured_at": ISO8601DateFormatter().string(from: match.item.capturedAt),
             "excerpt": match.excerpt, "reason": match.reason, "matched_terms": match.matchedTerms, "tier": match.tier, "score": match.score,
             "source": ["id": match.id, "path": match.item.sourcePath, "read_action": "item.read"]]
        }
        return ["results": results, "query": resolved.text, "engine": "native_capture_index", "semantic": useSemantic ? (SearchService.semanticAvailable ? "enabled" : "unavailable") : "disabled",
                "filters": ["kind": resolved.filter.kind, "after": resolved.filter.after.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "before": resolved.filter.before.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "theme": resolved.filter.themeID as Any? ?? NSNull(), "pinned_only": resolved.filter.pinnedOnly],
                "next_offset": offset + results.count < matches.count ? offset + results.count as Any : NSNull(), "partial": matches.count == cap, "result_cap": cap]
    }
}
