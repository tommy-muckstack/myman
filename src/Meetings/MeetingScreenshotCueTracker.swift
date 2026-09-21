import Foundation

/// Lightweight local context tracking. This never queues another model while
/// speech recognition is running; the image pipeline still rejects duplicates.
struct MeetingScreenshotCueTracker {
    private var seen: Set<String> = []
    private var screenContextUntil: TimeInterval = -.infinity
    private var lastRequest: TimeInterval = -.infinity

    mutating func shouldCapture(turns: [MeetingTurn], elapsed: TimeInterval) -> Bool {
        var reference = false
        for turn in turns.suffix(30) {
            let key = "\(turn.start):\(turn.speaker):\(turn.text)"
            guard seen.insert(key).inserted else { continue }
            // Catch-up transcription must not photograph today's screen for
            // a visual reference made much earlier in the recording.
            guard turn.end >= elapsed - 90 else { continue }
            let text = Self.normalized(turn.text)
            if Self.contains(text, ["stopped sharing", "stop sharing", "no longer sharing", "nothing on my screen"]) {
                screenContextUntil = -.infinity
                reference = false
                continue
            }
            let context = turn.start <= screenContextUntil
            if Self.isVisualReference(text, hasScreenContext: context) { reference = true }
            if Self.establishesScreenContext(text) { screenContextUntil = turn.end + 300 }
        }
        if seen.count > 600 {
            seen = Set(turns.suffix(30).map { "\($0.start):\($0.speaker):\($0.text)" })
        }
        guard reference, elapsed - lastRequest >= 20 else { return false }
        lastRequest = elapsed
        return true
    }

    static func isVisualReference(_ source: String, hasScreenContext: Bool) -> Bool {
        let text = normalized(source)
        // Quoted stories, deferred demos, and everyday uses of "see" should
        // not trigger a screenshot of the current call.
        guard !isNonCurrentReference(text) else { return false }
        let visual = contains(text, ["this slide", "this chart", "this graph", "this table", "this dashboard",
                                     "these columns", "these rows", "this diagram", "this screen", "this page",
                                     "this button", "this section", "this code", "this image", "this example"])
        let attention = contains(text, ["look", "looking", "see", "notice", "compare", "highlight", "point out", "walk through", "show you"])
        let location = contains(text, ["on the left", "on the right", "top left", "top right", "bottom left", "bottom right",
                                      "right hand side", "left hand side", "at the top", "at the bottom"])
        if visual && (attention || location) { return true }
        if contains(text, ["on this slide", "on this chart", "on this graph", "as you can see on", "let me show you",
                            "i'll show you", "sharing my screen", "share my screen", "can you see my screen", "can everyone see my screen"]) { return true }
        guard hasScreenContext else { return false }
        return location || contains(text, ["look at this", "take a look here", "see here", "you can see", "notice how",
                                           "notice that", "watch what happens", "click here", "scroll down", "zoom in",
                                           "next slide", "go back a slide", "these numbers", "this highlighted"])
    }

    private static func establishesScreenContext(_ text: String) -> Bool {
        !isNonCurrentReference(text) && contains(text, ["sharing my screen", "share my screen", "screen share", "on your screen", "on my screen",
                        "this slide", "this chart", "this graph", "this dashboard", "this demo", "these columns"])
    }
    private static func isNonCurrentReference(_ text: String) -> Bool {
        contains(text, ["he said", "she said", "they said", "i said", "i told", "we told", "used to", "we would", "back then", "back when",
                        "tomorrow", "next week", "after the call", "look at it later", "show you later",
                        "can't see", "cannot see", "don't see", "not sharing", "don't look"])
    }
    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { (" " + text + " ").contains(" " + $0 + " ") }
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
