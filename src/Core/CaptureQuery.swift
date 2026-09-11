import Foundation

/// Small, predictable query conveniences. Explicit filter choices win; quoted
/// text is left intact. No model call or observation of foreground activity.
enum CaptureQuery {
    static func resolve(_ query: String, filter: CaptureFilter, now: Date = Date()) -> (text: String, filter: CaptureFilter, hint: String?) {
        guard !query.contains("\"") else { return (query, filter, nil) }
        let words = CaptureText.words(query)
        let conversational = words.count >= 4 && words.contains { ["find", "show", "remember", "that", "screenshotted", "somebody", "sometime", "what"].contains($0) }
        guard conversational else { return (query, filter, nil) }
        var result = filter
        var text = query.lowercased()
        var hints: [String] = []
        let kinds: [(String, [String])] = [("screenshot", ["screenshot", "screenshots", "screenshotted"]), ("meeting", ["meeting", "meetings"]), ("dictation", ["dictation", "dictations", "dictated"]), ("recording", ["recording", "recordings"]), ("note", ["notes"])]
        let detected = kinds.filter { !$0.1.filter(words.contains).isEmpty }
        if detected.count == 1, result.kind == "all" { result.kind = detected[0].0; hints.append(result.kind.capitalized) }
        if result.after == nil && result.before == nil {
            if text.contains("last week"), let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) {
                result.before = week.start; result.after = Calendar.current.date(byAdding: .day, value: -7, to: week.start)
                text = text.replacingOccurrences(of: "last week", with: ""); hints.append("Last week")
            } else if text.contains("yesterday") {
                result.before = Calendar.current.startOfDay(for: now); result.after = Calendar.current.date(byAdding: .day, value: -1, to: result.before!)
                text = text.replacingOccurrences(of: "yesterday", with: ""); hints.append("Yesterday")
            }
        }
        let filler = Set("i a an the that this what have captured where when was were is in on of from for to my me it somebody mentioning mentioned remember find show sometime everything related work working saw heard discussed number page".split(separator: " ").map(String.init))
        let typeWords = detected.count == 1 ? Set(detected[0].1) : []
        // Keep punctuation attached to useful tokens, including prices/URLs.
        let retained = text.split(whereSeparator: \.isWhitespace).filter { token in
            let normalized = CaptureText.words(String(token))
            return !normalized.allSatisfy { filler.contains($0) || typeWords.contains($0) }
        }.joined(separator: " ")
        return (retained, result, hints.isEmpty ? nil : hints.joined(separator: " · "))
    }
}
