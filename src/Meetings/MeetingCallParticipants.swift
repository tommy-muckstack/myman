import AppKit
import Foundation

/// Names read off the call window (participant tiles, the participants
/// panel). Zoom, Meet and Teams all draw a person's name next to their
/// video, so OCR of the window we already capture for slides tells us who
/// is on the call — including people the calendar never listed.
enum MeetingCallParticipants {
    /// Words that appear on call UIs and are never someone's name.
    static let uiWords: Set<String> = [
        "mute", "unmute", "stop", "start", "video", "share", "screen", "record", "recording", "reactions",
        "apps", "more", "leave", "end", "view", "gallery", "speaker", "chat", "participants", "meeting",
        "zoom", "google", "meet", "teams", "microsoft", "host", "present", "now", "whiteboard", "captions",
        "raise", "hand", "call", "join", "audio", "settings", "security", "polls", "breakout", "rooms",
        "notes", "summary", "companion", "live", "transcript", "everyone", "you", "me", "guest", "phone",
        "workspace", "workplace", "people", "activities", "camera", "microphone", "connect", "connecting",
        "waiting", "room", "admit", "invite", "copy", "link", "search", "pin", "spotlight", "hide", "show",
        "self", "original", "sound", "fullscreen", "exit", "minimize", "close", "menu", "file", "edit",
        "window", "help", "new", "today", "tomorrow", "yesterday", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december", "ok", "yes", "no", "on", "off",
        "the", "and", "for", "with", "from", "your", "our", "their", "this", "that", "not", "are", "is",
        "am", "pm", "ai", "hd", "cc", "id", "url", "app", "web", "beta", "pro", "free", "upgrade", "plan",
        "muted", "unmuted", "sharing", "stopped", "started", "presenting", "ended", "paused",
        "ask", "gemini", "copilot", "assistant", "notetaker", "bot", "fireflies", "otter", "read", "fathom",
        "granola", "tactiq", "unknown", "caller", "device", "screen", "display", "browser", "tab", "meeting",
        "lobby", "waiting", "reconnecting", "poor", "connection", "network", "quality", "stereo", "speakers",
    ]

    /// Suffixes call apps append to a name on a tile.
    private static let roleSuffix = try! NSRegularExpression(
        pattern: #"\s*[(\[](?:host|co-host|cohost|me|you|guest|organizer|presenter|external|unverified)[)\]]\s*$"#,
        options: .caseInsensitive)

    /// Name-like lines: two to four capitalized words of letters, or a
    /// single word that matches a name we already expect. UI vocabulary,
    /// shouting, digits and long strings are never names.
    static func names(in lines: [String], owner: String, knownNames: [String] = []) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in lines {
            guard let name = cleanName(raw, knownNames: knownNames) else { continue }
            if LiveMeetingTranscript.sameName(name, owner) { continue }
            let key = name.lowercased()
            if seen.insert(key).inserted { result.append(name) }
        }
        // "Michelle" next to "Michelle Shih" is the same tile read twice.
        return result.filter { name in
            name.contains(" ") || !result.contains { $0 != name && $0.contains(" ") && LiveMeetingTranscript.sameName($0, name) }
        }
    }

    static func cleanName(_ raw: String, knownNames: [String] = []) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = roleSuffix.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // Drop tile decorations: mic/pin glyphs OCR turns into punctuation.
        text = text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
        guard !text.isEmpty, text.count <= 40, text.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...4).contains(words.count) else { return nil }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'’-."))
        for word in words {
            guard word.count <= 20, word.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  word.first?.isUppercase == true, word != word.uppercased() || word.count <= 2,
                  !uiWords.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'’-."))) else { return nil }
        }
        if words.count == 1 {
            // A lone first name is only trusted when we already expect it.
            guard knownNames.contains(where: { LiveMeetingTranscript.sameName($0, text) }) else { return nil }
        }
        return words.joined(separator: " ")
    }
}

/// Runs OCR on call-window captures and reports names seen on at least two
/// separate captures (one sighting is enough for a name the calendar
/// already listed), so a stray line of chat never becomes a person.
@MainActor
final class CallParticipantScanner {
    private var sightings: [String: (name: String, count: Int)] = [:]
    private var scanning = false

    func ingest(_ image: CGImage, owner: String, knownNames: [String]) async -> [String] {
        guard !scanning else { return confirmed(knownNames: knownNames) }
        scanning = true
        defer { scanning = false }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let lines = await ImageAnalysis.textObservations(nsImage).map(\.text)
        for name in MeetingCallParticipants.names(in: lines, owner: owner, knownNames: knownNames) {
            let key = name.lowercased()
            sightings[key] = (name, (sightings[key]?.count ?? 0) + 1)
        }
        return confirmed(knownNames: knownNames)
    }

    func confirmed(knownNames: [String]) -> [String] {
        sightings.values.filter { entry in
            entry.count >= 2 || knownNames.contains { LiveMeetingTranscript.sameName($0, entry.name) }
        }
        .map(\.name)
        .sorted()
    }

    func reset() { sightings = [:] }
}
