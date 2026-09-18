import Foundation

/// Conservative calendar evidence and export metadata, shared by both exporters.
enum MeetingConversation {
    static func explicitPair(title: String, owner: String) -> (owner: String, remote: String)? {
        let parts = title.components(separatedBy: "<>")
        guard parts.count == 2 else { return nil }
        let left = String(parts[0].split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        func person(_ value: String) -> Bool {
            let words = value.split(separator: " ")
            return (2...5).contains(words.count) && value.allSatisfy { $0.isLetter || " ()'-’.".contains($0) }
        }
        guard person(left), person(right) else { return nil }
        let ownerWords = Set(MeetingSource.words(owner))
        func matches(_ value: String) -> Bool { ownerWords.count >= 2 && ownerWords.isSubset(of: Set(MeetingSource.words(value))) }
        guard matches(left) != matches(right) else { return nil }
        return (owner, matches(left) ? right : left)
    }

    static func finish(_ transcript: String, meeting: Meeting) -> String {
        let owner = meeting.ownerName.isEmpty ? NSFullUserName() : meeting.ownerName
        let pair = explicitPair(title: meeting.title, owner: owner)
        var turns = MeetingSource.parse(transcript).map {
            MeetingTurn(start: $0.seconds, end: $0.seconds, speaker: $0.speaker == "You" ? owner : $0.speaker, text: $0.text)
        }
        if let pair, meeting.captureKind == .meeting {
            turns = turns.map { turn in
                var copy = turn
                if turn.speaker != pair.owner { copy.speaker = pair.remote }
                return copy
            }
            // Preserve recording-relative timestamps, and archive the full raw
            // transcript separately. Only remove the solo pre-call interval.
            if let firstRemote = turns.first(where: { $0.speaker == pair.remote })?.start {
                turns.removeAll { $0.start < firstRemote }
            }
        }
        return MeetingSource.render(turns)
    }

    static func metadata(transcript: String, summary: String, title: String, owner: String,
                         started: Date, ended: Date?, participants: [String], originalTranscript: String = "", analysisJSON: String = "") -> [String] {
        let status = ended != nil && !transcript.isEmpty && !summary.isEmpty ? "complete" : "transcribing"
        var fields = ["status: \(status)"]
        let turns = MeetingSource.parse(transcript)
        if let remote = turns.first(where: { $0.speaker != "You" && $0.speaker != owner && !MeetingSource.isBackchannel($0.text) }),
           !remote.timestamp.isEmpty {
            fields += ["call_started_at: \(ISO8601DateFormatter().string(from: started.addingTimeInterval(remote.seconds)))",
                       "call_start_offset_seconds: \(Int(remote.seconds))", "timestamp_origin: recording_start"]
        }
        var flags = MeetingVocabulary.flaggedTokens(in: turns.map(\.text).joined(separator: " "), context: ([title] + participants).joined(separator: " "))
        let originals = MeetingSource.parse(originalTranscript)
        var occurrences: [String: Int] = [:]
        for turn in turns {
            let occurrence = occurrences[turn.timestamp, default: 0]
            occurrences[turn.timestamp] = occurrence + 1
            let matching = originals.filter { $0.timestamp == turn.timestamp }
            guard matching.indices.contains(occurrence) else { continue }
            let original = matching[occurrence]
            guard original.text != turn.text else { continue }
            let before = original.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let after = turn.text.split(whereSeparator: \.isWhitespace).map(String.init)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix,
                  before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
            let old = before[prefix..<(before.count - suffix)].joined(separator: " ")
            let new = after[prefix..<(after.count - suffix)].joined(separator: " ")
            flags.append("[\(turn.timestamp)] \(old) → \(new)")
        }
        let json = (try? JSONSerialization.data(withJSONObject: flags)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        fields.append("flagged_hotwords: \(json)")
        let analysis = try? JSONDecoder().decode(MeetingAnalysis.self, from: Data(analysisJSON.utf8))
        let omit = analysis?.omissionEnabled ?? summary.contains("Private passages omitted")
        fields.append("omission_policy: \(omit ? "omit_private" : "owner_full")")
        let publicIDs = Set(MeetingSource.publicTurns(turns).map(\.id))
        let excluded = omit ? turns.filter { !publicIDs.contains($0.id) && !MeetingSource.isBackchannel($0.text) } : []
        var omitted: [[String: String]] = []
        var run: [MeetingSourceTurn] = []
        func appendRun() {
            guard let first = run.first, let last = run.last else { return }
            omitted.append(["range": first.timestamp + "–" + last.timestamp,
                "reason": "Privacy marker and surrounding context; retained in the owner’s transcript."])
            run = []
        }
        for turn in excluded {
            if let last = run.last, turn.seconds - last.seconds > 30 { appendRun() }
            run.append(turn)
        }
        appendRun()
        let omissionsJSON = (try? JSONSerialization.data(withJSONObject: omitted, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        fields.append("omitted: \(omissionsJSON)")
        return fields
    }
}
