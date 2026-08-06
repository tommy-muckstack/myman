import EventKit
import Foundation

/// Calendar answers are deliberately deterministic. A question about today's
/// schedule must never be improvised from old meeting notes or an LLM guess.
enum BrainCalendar {
    static func isTodayScheduleQuestion(_ question: String) -> Bool {
        let text = question.lowercased()
        let asksToday = text.contains("today") || text.contains("this afternoon") || text.contains("this morning")
        let asksSchedule = ["meeting", "calendar", "schedule", "agenda", "what do i have", "what's on"].contains {
            text.contains($0)
        }
        return asksToday && asksSchedule
    }

    static func todayAnswer(now: Date = Date()) -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "I can’t see your calendar yet, so I can’t tell you what meetings you have today. Allow Calendar access in My Man’s settings and ask again."
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return "I couldn’t read today’s calendar."
        }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "You have no timed calendar events today." }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "h:mm a"
        let lines = events.map { event in
            let end = event.endDate.map { "–\(formatter.string(from: $0))" } ?? ""
            return "• \(formatter.string(from: event.startDate))\(end) — \(event.title ?? "Untitled")"
        }
        return "Here’s your calendar for today:\n" + lines.joined(separator: "\n")
    }

    static func snapshotForContext(now: Date = Date()) -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "CALENDAR TODAY: unavailable (permission not granted)."
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return "CALENDAR TODAY: unavailable." }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        return events.isEmpty
            ? "CALENDAR TODAY: no timed events."
            : "CALENDAR TODAY:\n" + events.map { "\(formatter.string(from: $0.startDate)) \($0.title ?? "Untitled")" }.joined(separator: "\n")
    }
}
