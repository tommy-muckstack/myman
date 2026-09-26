import Foundation

/// Read-only schedule requests. Exact grammar keeps calendar phrases from
/// swallowing searches for saved meeting notes or requests to create events.
enum LauncherCalendarRequest: Equatable {
    case today, tomorrow, weekday(Int), week, upcoming, next

    static func parse(_ input: String) -> Self? {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.hasPrefix("show me ") { text = String(text.dropFirst(8)) }
        if ["calendar", "my calendar", "schedule", "my schedule", "agenda", "my agenda"].contains(text) { return .today }
        if ["what's next", "what is next", "what's up next", "next meeting", "my next meeting", "next event",
            "what's my next meeting", "what is my next meeting", "when is my next meeting"].contains(text) { return .next }
        if ["upcoming meetings", "upcoming events", "upcoming schedule", "next 7 days"].contains(text) { return .upcoming }

        func period(_ text: String) -> Self? {
            let text = text.hasPrefix("on ") ? String(text.dropFirst(3)) : text
            switch text {
            case "today": return .today
            case "tomorrow": return .tomorrow
            case "this week": return .week
            default:
                let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
                return weekdays.firstIndex(where: { $0 == text || String($0.prefix(3)) == text }).map { .weekday($0 + 1) }
            }
        }
        for prefix in ["what's on my calendar ", "what is on my calendar ", "what's on my schedule ",
                       "what is on my schedule ", "what's on ", "what is on ", "what do i have "] {
            if text.hasPrefix(prefix) { return period(String(text.dropFirst(prefix.count))) }
        }
        for noun in ["calendar", "agenda", "schedule", "meetings", "events"] {
            for prefix in [noun + " ", "my " + noun + " "] where text.hasPrefix(prefix) {
                let rest = String(text.dropFirst(prefix.count))
                return period(rest.hasPrefix("for ") ? String(rest.dropFirst(4)) : rest)
            }
            for (prefix, request) in [("today's ", Self.today), ("tomorrow's ", .tomorrow), ("this week's ", .week)] {
                if text == prefix + noun { return request }
            }
        }
        return nil
    }

    func startDate(now: Date = .now, calendar: Calendar = .current) -> Date {
        if self == .week, let interval = calendar.dateInterval(of: .weekOfYear, for: now) { return interval.start }
        return calendar.startOfDay(for: now)
    }

    func selectedDate(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let offset: Int
        switch self {
        case .tomorrow: offset = 1
        case .weekday(let weekday): offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7
        default: offset = 0
        }
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }
}
