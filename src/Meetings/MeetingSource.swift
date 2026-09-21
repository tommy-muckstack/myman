import Foundation

enum MeetingKind: String, Codable, Sendable { case meeting, listening }

struct MeetingParticipant: Codable, Equatable, Sendable {
    var name: String
    var email: String?
    var isOwner: Bool = false
}

struct MeetingSourceTurn: Codable, Equatable, Sendable {
    let id: Int
    let speaker: String
    let timestamp: String
    let text: String
    var seconds: Double {
        let parts = timestamp.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }
    var prompt: String { "[T\(id)] **\(speaker)** [\(timestamp)]: \(text)" }
}

enum MeetingSource {
    static func parse(_ transcript: String) -> [MeetingSourceTurn] {
        let pattern = #"(?m)^\*\*([^*\n]+)\*\*\s*\[(\d+:\d{2})\]:[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            // Older captures have named blocks but no timing evidence. Keep
            // their content available without manufacturing timestamps.
            let legacy = try! NSRegularExpression(pattern: #"(?m)^([A-Za-z][A-Za-z0-9 .'\-]{0,39}):[ \t]*\n"#)
            let labels = legacy.matches(in: transcript, range: NSRange(location: 0, length: ns.length))
            if labels.isEmpty {
                return transcript.isEmpty ? [] : [MeetingSourceTurn(id: 0, speaker: "Speaker unclear", timestamp: "", text: transcript)]
            }
            return labels.enumerated().map { index, match in
                let start = NSMaxRange(match.range)
                let end = index + 1 < labels.count ? labels[index + 1].range.location : ns.length
                return MeetingSourceTurn(id: index, speaker: ns.substring(with: match.range(at: 1)), timestamp: "",
                    text: ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return matches.enumerated().map { index, match in
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return MeetingSourceTurn(id: index, speaker: ns.substring(with: match.range(at: 1)),
                                     timestamp: ns.substring(with: match.range(at: 2)),
                                     text: ns.substring(with: NSRange(location: start, length: end - start))
                                        .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }

    /// A narrow noise list. Never reject unfamiliar names, numbers, or short
    /// meaningful phrases merely because a language dictionary lacks them.
    static func isBackchannel(_ text: String) -> Bool {
        let tokens = words(text)
        if tokens.isEmpty { return true }
        let fillers: Set<String> = ["yeah", "yes", "uh", "huh", "hmm", "hm", "mm", "mhm", "right", "nice", "cool", "ok", "okay", "cough", "coughing", "ha", "haha", "laugh", "laughing", "um", "ah"]
        return tokens.count <= 6 && tokens.allSatisfy { fillers.contains($0) }
    }

    static func stamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    static func render(_ turns: [MeetingTurn]) -> String {
        turns.map { "**\($0.speaker)** [\(stamp($0.start))]: \($0.text)" }.joined(separator: "\n\n")
    }

    static func genericSpeaker(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("speaker ") || ["", "you", "owner", "host", "guest", "them", "others", "unknown", "speaker unclear"].contains(value)
    }

    static let privacyMarkers = ["just between us", "don't share this", "do not share this", "confidential", "off the record", "keep this private", "not for sharing"]

    /// ASR emits five-second pieces. Read adjacent pieces as speech, without
    /// crossing speakers or time gaps. IDs/timestamps still anchor the first
    /// original piece; the stored transcript is never changed here.
    static func paragraphs(_ turns: [MeetingSourceTurn], maximumGap: Double = 15) -> [MeetingSourceTurn] {
        var result: [MeetingSourceTurn] = []
        var previousSeconds: Double = -100
        for turn in turns {
            if let last = result.last, last.speaker == turn.speaker,
               turn.seconds >= previousSeconds, turn.seconds - previousSeconds <= maximumGap,
               !genericSpeaker(turn.speaker), last.text.count + turn.text.count < 4000 {
                result[result.count - 1] = .init(id: last.id, speaker: last.speaker,
                    timestamp: last.timestamp, text: last.text + " " + turn.text)
            } else { result.append(turn) }
            previousSeconds = turn.seconds
        }
        return result
    }

    /// These are presentation/summary exclusions, never transcript deletions.
    /// Start-only legacy transcripts cannot prove a 1.5-second duration. Require
    /// a tightly interleaved A/B/A pattern plus acknowledgment/noise wording;
    /// short corrections, questions and commitments remain evidence.
    static func contextualBackchannelIDs(_ turns: [MeetingSourceTurn]) -> Set<Int> {
        guard turns.count >= 3 else { return [] }
        let repeated = Dictionary(grouping: turns, by: { normalized($0.text) })
        var result = Set<Int>()
        for index in 1..<(turns.count - 1) {
            let prior = turns[index - 1], turn = turns[index], next = turns[index + 1]
            if ["cake", "ow"].contains(normalized(turn.text)), prior.speaker == turn.speaker,
               next.speaker == turn.speaker, !prior.timestamp.isEmpty, !next.timestamp.isEmpty,
               next.seconds >= prior.seconds, next.seconds - prior.seconds <= 8 {
                result.insert(turn.id); continue
            }
            guard !turn.timestamp.isEmpty, !prior.timestamp.isEmpty, !next.timestamp.isEmpty,
                  prior.speaker == next.speaker, turn.speaker != prior.speaker,
                  !genericSpeaker(prior.speaker), turn.seconds >= prior.seconds,
                  turn.seconds - prior.seconds <= 6, next.seconds >= turn.seconds,
                  next.seconds - turn.seconds <= 6 else { continue }
            let value = normalized(turn.text), count = words(turn.text).count
            let acknowledgment = ["let s do it", "we have to do that", "cake", "ow", "awesome", "sure", "totally"]
            let repeatedBoilerplate = count <= 9 && (repeated[value]?.count ?? 0) >= 2
                && ["i think that s a good thing", "and i think that s a good thing"].contains(value)
            if isBackchannel(turn.text) || (count <= 6 && acknowledgment.contains(value)) || repeatedBoilerplate {
                result.insert(turn.id)
            }
        }
        return result
    }

    static var omitPrivateNotes: Bool {
        UserDefaults.standard.bool(forKey: "meetingOmitPrivateNotes")
    }

    static func notesTurns(_ turns: [MeetingSourceTurn], omitPrivate: Bool = omitPrivateNotes) -> [MeetingSourceTurn] {
        let noise = contextualBackchannelIDs(turns)
        return (omitPrivate ? publicTurns(turns) : turns).filter { !isBackchannel($0.text) && !noise.contains($0.id) }
    }

    /// Omit flagged passages and their immediate conversational context before
    /// any derived model sees them. Keep the original transcript untouched.
    static func publicTurns(_ turns: [MeetingSourceTurn]) -> [MeetingSourceTurn] {
        let flagged = turns.filter { turn in privacyMarkers.contains { turn.text.localizedCaseInsensitiveContains($0) } }
        guard !flagged.isEmpty else { return turns.filter { !isBackchannel($0.text) } }
        guard flagged.allSatisfy({ !$0.timestamp.isEmpty }) else { return [] }
        let sensitiveWords: Set<String> = ["interview", "interviews", "onsite", "salary", "diagnosis", "password", "acquisition", "layoffs"]
        let privateTopics = Set(flagged.flatMap { words($0.text) }).intersection(sensitiveWords)
        return turns.filter { turn in
            guard !isBackchannel(turn.text) else { return false }
            // "Don't share this" can refer to the preceding sentence too.
            guard !flagged.contains(where: { turn.seconds >= $0.seconds - 60 && turn.seconds <= $0.seconds + 120 }) else { return false }
            return Set(words(turn.text)).isDisjoint(with: privateTopics)
        }
    }

    /// Windows always carry independent source ids, labels, and timestamps.
    /// Oversized legacy turns are split while retaining their ORIGINAL anchor;
    /// no interpolated time is passed off as a measured speech timestamp.
    static func windows(_ turns: [MeetingSourceTurn], limit: Int = 6000) -> [String] {
        var windows: [String] = []; var current = ""
        for turn in turns {
            let blocks = chunks(turn.text, limit: min(1100, limit - 150))
            for block in blocks {
                let line = "[T\(turn.id)] **\(turn.speaker)** [\(turn.timestamp)]: \(block)"
                if current.count + line.count + 2 > limit, !current.isEmpty { windows.append(current); current = "" }
                current += (current.isEmpty ? "" : "\n\n") + line
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = []; var remaining = text[...]
        while remaining.count > limit {
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            let split = remaining[..<end].lastIndex(where: { $0.isWhitespace }) ?? end
            guard split > remaining.startIndex else { break }
            result.append(String(remaining[..<split]))
            remaining = remaining[split...].drop(while: { $0.isWhitespace })
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }
}

struct MeetingTranscriptResult: Sendable {
    var transcript: String
    var originalTranscript: String
    var kind: MeetingKind
}

enum MeetingChannelDedupe {
    static func grams(_ text: String) -> Set<String> {
        let tokens = MeetingSource.words(text)
        guard tokens.count >= 3 else { return [] }
        return Set((0..<(tokens.count - 2)).map { tokens[$0...($0 + 2)].joined(separator: " ") })
    }

    static func clean(mic: [MeetingTurn], system: [MeetingTurn], echo: AudioEchoEvidence = .none) -> (mic: [MeetingTurn], system: [MeetingTurn], kind: MeetingKind) {
        let remote = system.filter { !MeetingSource.isBackchannel($0.text) }
        let allRemote = grams(remote.map(\.text).joined(separator: " "))
        let retained = mic.filter { turn in
            guard !MeetingSource.isBackchannel(turn.text) else { return false }
            let candidate = grams(turn.text)
            guard candidate.count >= 6 else { return true }
            let nearby = remote.filter { $0.start <= turn.end + 12 && $0.end >= turn.start - 12 }
            let local = grams(nearby.map(\.text).joined(separator: " "))
            let localCoverage = Double(candidate.intersection(local).count) / Double(candidate.count)
            if localCoverage >= 0.72 { return false }
            // Acoustic echo plus substantial repeated wording handles channel
            // drift/ASR boundary differences. Correlation alone never deletes speech.
            let totalCoverage = Double(candidate.intersection(allRemote).count) / Double(candidate.count)
            return !(echo.supportsEcho(at: turn.start) && totalCoverage >= 0.50)
        }
        return (retained, remote, retained.isEmpty && !remote.isEmpty ? .listening : .meeting)
    }
}
