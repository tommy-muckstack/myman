import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Action items, as commitments rather than topics.
//
// The old extractor asked one prompt for a summary AND action items, and got
// back imperatives nobody said: "Explore AI-driven Solutions", "Review and
// Adjust Testing Strategies". Meanwhile the real commitments in the same
// meeting — who was sending what to whom by when — went missing entirely.
//
// So this is a separate pass with a schema instead of a wish: every item must
// name an owner, cite the timestamp it was said at, and carry the deadline as
// spoken, which we then resolve against the meeting's own date. Extracting
// nothing is a correct answer, and a much better one than inventing three.

enum ActionItemExtractor {
    /// Markdown bullets, one per real commitment. Empty when nobody committed
    /// to anything — which is the common case for a status call.
    static func extract(from transcript: String, meetingDate: Date) async -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "" }
        guard case .available = SystemLanguageModel.default.availability else { return "" }
        var items: [Commitment] = []
        for window in windows(of: transcript, size: 7000) {
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(
                to: window, generating: CommitmentList.self) else { continue }
            items += response.content.items
        }
        let index = TranscriptIndex(transcript: transcript)
        let cleaned = dedupe(items.filter(isRealCommitment))
        // An item the transcript cannot back — a timestamp pointing at no
        // line, an owner who never spoke — is an invention wearing a
        // citation. Three real items beat eight where three are made up,
        // because the invented ones cost more to detect than the real ones
        // save. Drop, don't ship.
        let supported = cleaned.filter {
            index.supports(owner: $0.owner, timestamp: $0.timestamp)
        }
        if supported.count < cleaned.count {
            Analytics.track("meeting_action_items_dropped_unsupported",
                            ["dropped": cleaned.count - supported.count,
                             "kept": supported.count])
        }
        guard !supported.isEmpty else { return "" }
        return supported.map { line(for: $0, meetingDate: meetingDate) }
            .joined(separator: "\n")
        #else
        return ""
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static var instructions: String {
        """
        You extract COMMITMENTS from a meeting transcript. Lines look like \
        "**Name** [minute:second]: what they said", and "You" is the user.

        A commitment is someone stating that they (or a named person) WILL do \
        a specific thing. "I'll send the doc tonight" is a commitment. "We \
        should think about pricing", "it would be good to explore X", and \
        anything merely discussed, considered, or described is NOT — do not \
        include it. Topics are not action items.

        For each one, give the owner's speaker label exactly as it appears in \
        the transcript, the task in plain words, the deadline exactly as it \
        was spoken (or empty if none was), and the timestamp of the line \
        where it was said.

        Most meetings contain few commitments and many contain none. \
        Returning an empty list is correct and expected. Never invent an item \
        to fill the list.
        """
    }

    @available(macOS 26.0, *)
    @Generable
    fileprivate struct Commitment: Equatable {
        @Guide(description: "The speaker label of whoever committed, exactly as written in the transcript, e.g. 'You' or 'Lauren Comer'. Empty if genuinely unclear.")
        var owner: String
        @Guide(description: "What they committed to do, plain language, under 15 words. No leading verb-capitalised title case.")
        var task: String
        @Guide(description: "The deadline exactly as spoken, e.g. 'Wednesday EOD' or 'this afternoon'. Empty if no deadline was stated.")
        var due: String
        @Guide(description: "Timestamp of the transcript line where this was said, formatted minute:second, e.g. '14:32'.")
        var timestamp: String
    }

    @available(macOS 26.0, *)
    @Generable
    fileprivate struct CommitmentList {
        @Guide(description: "Every commitment in this part of the transcript. Empty when there are none.")
        var items: [Commitment]
    }

    /// Cheap guards against the failure this whole pass exists to prevent: a
    /// topic dressed up as a task, with nothing behind it.
    @available(macOS 26.0, *)
    private static func isRealCommitment(_ item: Commitment) -> Bool {
        let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.count >= 8, task.split(separator: " ").count >= 2 else { return false }
        // "Explore AI-driven Solutions" — Title Case With No Owner is the
        // signature of a restated agenda item, not something someone said.
        let words = task.split(separator: " ")
        let titleCased = words.count >= 3 && words.allSatisfy { $0.first?.isUppercase ?? false }
        if titleCased, item.owner.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    @available(macOS 26.0, *)
    private static func dedupe(_ items: [Commitment]) -> [Commitment] {
        var seen = Set<String>()
        return items.filter {
            let key = ($0.owner + "|" + $0.task).lowercased()
                .filter { !$0.isWhitespace && !$0.isPunctuation }
            return seen.insert(key).inserted
        }
    }

    @available(macOS 26.0, *)
    private static func line(for item: Commitment, meetingDate: Date) -> String {
        let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["**\(owner.isEmpty ? "Unassigned" : owner)**"]
        parts.append(item.task.trimmingCharacters(in: .whitespacesAndNewlines))
        let due = item.due.trimmingCharacters(in: .whitespacesAndNewlines)
        if !due.isEmpty {
            if let resolved = DueDate.resolve(due, from: meetingDate) {
                parts.append("due \(resolved)")
            } else {
                parts.append("due \(due)")
            }
        }
        var line = "- " + parts.joined(separator: " — ")
        let stamp = item.timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        // The citation is the point: an item you cannot go check is an item
        // you cannot trust.
        if stamp.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil {
            line += " [\(stamp)]"
        }
        return line
    }
    #endif

    /// Split on turn boundaries so no utterance is cut in half.
    private static func windows(of transcript: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for block in transcript.components(separatedBy: "\n\n") {
            if current.count + block.count + 2 > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? block : "\n\n" + block
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// The transcript's own speakers and timestamps, for checking a claimed
/// citation against what was actually said. Built once per extraction.
struct TranscriptIndex {
    let speakers: Set<String>
    let stamps: Set<String>

    init(transcript: String) {
        var speakers: Set<String> = []
        var stamps: Set<String> = []
        let pattern = #"\*\*([^*\n]{1,80})\*\*\s*\[(\d+:\d{2})\]:"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: transcript,
                                       range: NSRange(transcript.startIndex..., in: transcript)) {
                if let range = Range(match.range(at: 1), in: transcript) {
                    speakers.insert(String(transcript[range])
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let range = Range(match.range(at: 2), in: transcript),
                   let stamp = Self.canonicalStamp(String(transcript[range])) {
                    stamps.insert(stamp)
                }
            }
        }
        self.speakers = speakers
        self.stamps = stamps
    }

    /// True when the transcript can back this citation: the timestamp names
    /// a real line and the owner is somebody who actually appears. An old
    /// two-block transcript has no stamped lines to check against — then
    /// everything passes, as before.
    func supports(owner: String, timestamp: String) -> Bool {
        guard !stamps.isEmpty else { return true }
        guard let stamp = Self.canonicalStamp(timestamp), stamps.contains(stamp)
        else { return false }
        let who = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty || speakers.contains(who)
    }

    /// "04:32" and "4:32" are the same moment — compare them that way.
    static func canonicalStamp(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), parts[1].count == 2,
              let seconds = Int(parts[1]), (0..<60).contains(seconds), minutes >= 0
        else { return nil }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

/// "By Wednesday end of day", said in a meeting on a Monday, means a date.
/// Resolving it here — against the meeting's own date, not today's — is what
/// makes an action item actionable a week later.
enum DueDate {
    static func resolve(_ spoken: String, from meetingDate: Date) -> String? {
        let text = spoken.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: meetingDate)

        func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        func adding(_ days: Int) -> String { stamp(calendar.date(byAdding: .day, value: days, to: start) ?? start) }

        if text.contains("today") || text.contains("this afternoon")
            || text.contains("this morning") || text.contains("tonight")
            || text.contains("this evening") {
            return adding(0)
        }
        if text.contains("tomorrow") { return adding(1) }

        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                        "thursday": 5, "friday": 6, "saturday": 7]
        for (name, weekday) in weekdays where text.contains(name) {
            let offset = text.contains("next ") ? 7 : 0
            guard let next = nextDate(weekday: weekday, onOrAfter: start,
                                      calendar: calendar) else { return nil }
            return stamp(calendar.date(byAdding: .day, value: offset, to: next) ?? next)
        }
        if text.contains("end of week") || text.contains("eow") {
            return nextDate(weekday: 6, onOrAfter: start, calendar: calendar).map(stamp)
        }
        if text.contains("next week") { return adding(7) }
        if text.contains("end of month") || text.contains("eom") {
            guard let range = calendar.range(of: .day, in: .month, for: start),
                  let last = calendar.date(bySetting: .day, value: range.upperBound - 1, of: start)
            else { return nil }
            return stamp(last)
        }
        return nil
    }

    /// The given weekday, counting the meeting's own day as a match — "by
    /// Wednesday" said in a Wednesday meeting means that same day.
    private static func nextDate(weekday: Int, onOrAfter start: Date,
                                 calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: start)
        let delta = (weekday - current + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: start)
    }
}
