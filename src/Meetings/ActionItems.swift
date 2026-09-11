import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Compatibility entry point; notes and tasks share the same source-grounded extraction.

enum ActionItemExtractor {
    static func extract(from transcript: String, meetingDate: Date,
                        progress: @escaping MeetingNotesService.Progress = { _ in }) async -> String {
        let meeting = Meeting(id: "", title: "", startedAt: meetingDate, transcript: transcript)
        let result = await GroundedMeetingNotes.generate(meeting, progress: progress)
        return result.markdown.components(separatedBy: "## Action items\n\n").dropFirst().first ?? ""
    }
}

/// The transcript's own speakers and timestamps, for checking a claimed
/// citation against what was actually said. Built once per extraction.
struct TranscriptIndex {
    let speakers: Set<String>
    let stamps: Set<String>
    let turns: [MeetingSourceTurn]

    init(transcript: String) {
        turns = MeetingSource.parse(transcript)
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

    /// Owner and timestamp must belong to the same source turn.
    func supports(owner: String, timestamp: String) -> Bool {
        guard let stamp = Self.canonicalStamp(timestamp) else { return false }
        return turns.contains {
            Self.canonicalStamp($0.timestamp) == stamp && $0.speaker == owner
        }
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
    static func isTemporalExpression(_ text: String) -> Bool {
        let pattern = #"(?i)\b(?:today|tomorrow|tonight|this (?:morning|afternoon|evening)|monday|tuesday|wednesday|thursday|friday|saturday|sunday|(?:next|this|end of) (?:week|month)|eow|eom)\b|\b(?:january|february|march|april|may|june|july|august|september|october|november|december) \d{1,2}\b|\b(?:by|in|before) (?:january|february|march|april|may|june|july|august|september|october|november|december)\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

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
            if text.contains("next ") {
                // A weekday in the next calendar week (Monday–Sunday), not
                // the next occurrence plus another seven days.
                let current = (calendar.component(.weekday, from: start) + 5) % 7
                let target = (weekday + 5) % 7
                return adding(7 - current + target)
            }
            return nextDate(weekday: weekday, onOrAfter: start, calendar: calendar).map(stamp)
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
