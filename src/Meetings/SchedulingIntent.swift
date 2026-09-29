import Foundation

/// An unsaved interpretation, shared by the launcher and agent actions. People
/// are literal mentions, not resolved identities. No calendar or Contacts I/O.
struct SchedulingIntent: Codable, Equatable, Sendable {
    var title: String?
    var people: [String] = []
    var day: String?
    var time: String?
    var durationMinutes: Int?
    var issues: [String] = []
    let timeZone: String

    var missing: [String] {
        [("title", title == nil), ("day", day == nil), ("time", time == nil),
         ("duration_minutes", durationMinutes == nil)].filter(\.1).map(\.0)
    }

    var json: [String: Any] {
        ["title": title as Any? ?? NSNull(), "people": people,
         "day": day as Any? ?? NSNull(), "time": time as Any? ?? NSNull(),
         "duration_minutes": durationMinutes as Any? ?? NSNull(),
         "time_zone": timeZone, "missing": missing, "issues": issues,
         "needs_clarification": !missing.isEmpty || !issues.isEmpty,
         "side_effects": false, "requires_human_booking": true]
    }
}

/// Detector-style, English v1 grammar. All date arithmetic uses the supplied
/// reference and zone, never NSDataDetector's implicit current date or locale.
enum SchedulingIntentParser {
    static let maximumInputLength = 2_000

    static func parse(_ input: String, reference: Date, timeZone: TimeZone) -> SchedulingIntent {
        var result = SchedulingIntent(timeZone: timeZone.identifier)
        guard input.count <= maximumInputLength else {
            result.issues = ["input_too_long"]; return result
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !text.isEmpty else { return result }

        // Remove spans as they are consumed so duration digits never become times.
        let durations = take(#"\bfor\s+([+-]?\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#, from: &text)
        if durations.count == 1 {
            let match = durations[0]
            let value = (Double(match[1]) ?? 0) * (match[2].lowercased().hasPrefix("h") ? 60 : 1)
            if value >= 1, value <= 480, value.rounded() == value { result.durationMinutes = Int(value) }
            else { result.issues.append("invalid_duration") }
        } else if !durations.isEmpty { result.issues.append("ambiguous_duration") }

        let days = take(#"\b(?:(?:on\s+)?(\d{4}-\d{2}-\d{2})|(?:(?:on\s+)?(today|tomorrow))|(?:on\s+)?(?:(next|this)\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday))\b"#, from: &text)
        if days.count == 1 {
            let match = days[0]
            if !match[1].isEmpty {
                let formatter = DateFormatter()
                formatter.locale = calendar.locale; formatter.calendar = calendar
                formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                if let date = formatter.date(from: match[1]), formatter.string(from: date) == match[1] {
                    result.day = match[1]
                } else { result.issues.append("invalid_day") }
            } else {
                let today = calendar.startOfDay(for: reference)
                var offset = match[2].lowercased() == "tomorrow" ? 1 : 0
                if !match[4].isEmpty {
                    let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
                    let weekday = weekdays.firstIndex(of: match[4].lowercased())! + 1
                    offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7
                    if match[3].lowercased() == "next", offset == 0 { offset = 7 }
                }
                if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                    let parts = calendar.dateComponents([.year, .month, .day], from: date)
                    result.day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                }
            }
        } else if !days.isEmpty { result.issues.append("ambiguous_day") }

        let times = take(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\bat\s+(\d{1,2})(?::(\d{2}))?\b|\b(?:at\s+)?(noon|midnight)\b"#, from: &text)
        if times.count == 1 {
            let match = times[0]
            var hour = Int(match[1].isEmpty ? match[4] : match[1]) ?? 0
            let minute = Int(match[2].isEmpty ? match[5] : match[2]) ?? 0
            let meridiem = match[3].lowercased()
            if !match[6].isEmpty {
                hour = match[6].lowercased() == "noon" ? 12 : 0
                result.time = String(format: "%02d:00", hour)
            } else if minute > 59 || hour > 23 || (!meridiem.isEmpty && !(1...12).contains(hour)) {
                result.issues.append("invalid_time")
            } else if meridiem.isEmpty && (1...12).contains(hour) {
                result.issues.append("ambiguous_time")
            } else {
                if !meridiem.isEmpty { hour = hour % 12 + (meridiem == "pm" ? 12 : 0) }
                result.time = String(format: "%02d:%02d", hour, minute)
            }
        } else if !times.isEmpty { result.issues.append("ambiguous_time") }

        // Never silently interpret vague periods, ranges, recurrence or a second
        // time zone. Keep recognized fields but require clarification.
        let vague = take(#"\b(sometime|someday|soon|later|next week|this week|morning|afternoon|evening|tonight|whenever|every|weekly|daily)\b"#, from: &text)
        if !vague.isEmpty { result.issues.append("vague_or_recurring_schedule") }
        if !take(#"\b(?:UTC|GMT|EST|EDT|PST|PDT|CST|CDT|MST|MDT|[A-Za-z_]+/[A-Za-z_]+)\b"#, from: &text).isEmpty {
            result.issues.append("time_zone_in_text"); result.time = nil
        }
        // Leftover temporal syntax is unsupported, not a person's surname.
        if text.range(of: #"\b(?:at|on|for|between|until|from)\b|\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
            result.issues.append("unparsed_schedule")
        }

        text = text.replacingOccurrences(of: #"^\s*(?:please\s+)?(?:schedule|book|arrange|set up)\s+(?:a\s+|an\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        let pieces = text.components(separatedBy: try! NSRegularExpression(pattern: #"\bwith\b"#, options: .caseInsensitive))
        result.title = clean(pieces[0])
        if pieces.count == 2 {
            let names = pieces[1].components(separatedBy: try! NSRegularExpression(pattern: #"\s*(?:,|&|\band\b)\s*"#, options: .caseInsensitive))
            var seen = Set<String>()
            for name in names.compactMap(clean) {
                if validPerson(name), seen.insert(name.lowercased()).inserted { result.people.append(name) }
                else if !validPerson(name) { result.issues.append("unclear_people") }
            }
            if result.people.isEmpty { result.issues.append("unclear_people") }
        } else if pieces.count > 2 { result.issues.append("unclear_people") }
        if let title = result.title, ["or", "and", "a", "an", "please"].contains(title.lowercased()) { result.title = nil }
        result.issues = Array(Set(result.issues)).sorted()
        return result
    }

    static func validPerson(_ name: String) -> Bool {
        guard name.count <= 100, name.split(separator: " ").count <= 5 else { return false }
        let excluded = #"\b(at|on|for|or|sometime|someone|somebody|anyone|everyone|them|us|team|next|week|to|from|until|between)\b|\d"#
        return name.range(of: excluded, options: [.regularExpression, .caseInsensitive]) == nil
            && name.rangeOfCharacter(from: .letters) != nil
    }

    static func clean(_ text: String) -> String? {
        let value = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?;:")))
        return value.isEmpty ? nil : value
    }

    private static func take(_ pattern: String, from text: inout String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        let values = matches.map { match in
            (0..<match.numberOfRanges).map { index in
                match.range(at: index).location == NSNotFound ? "" : source.substring(with: match.range(at: index))
            }
        }
        for match in matches.reversed() {
            if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: " ") }
        }
        return values
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let source = self as NSString
        var start = 0, parts: [String] = []
        for match in regex.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            parts.append(source.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = NSMaxRange(match.range)
        }
        parts.append(source.substring(from: start))
        return parts
    }
}
