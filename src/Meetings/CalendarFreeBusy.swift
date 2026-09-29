import Foundation
import EventKit

struct CalendarBusyBlock: Equatable, Sendable {
    var start: Date
    var end: Date
}

/// Half-open, absolute intervals. No titles, calendar names, IDs or attendees
/// leave the EventKit adapter. The result describes only this user's calendars.
enum CalendarFreeBusy {
    static let maximumEvents = 10_000
    static let maximumRange: TimeInterval = 31 * 86_400

    static func range(_ args: [String: Any]) throws -> CalendarBusyBlock {
        guard let after = args["after"] as? String, let before = args["before"] as? String,
              let start = instant(after), let end = instant(before), end > start,
              end.timeIntervalSince(start) <= maximumRange else {
            throw AgentError("INVALID_ARGUMENTS", "after/before must be ISO 8601 timestamps with offsets spanning more than zero and at most 31 days.")
        }
        return CalendarBusyBlock(start: start, end: end)
    }

    static func instant(_ value: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let text = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: text.length)) else { return nil }
        let numbers = (1...6).map { Int(text.substring(with: match.range(at: $0)))! }
        guard numbers[0] >= 1, numbers[3] < 24, numbers[4] < 60, numbers[5] < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5])
        guard let local = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local) == components else { return nil }
        let zone = text.substring(with: match.range(at: 7))
        if zone != "Z" {
            let pieces = zone.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard pieces[0] < 24, pieces[1] < 60 else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        if value.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return formatter.date(from: value)
    }

    static func merge(_ blocks: [CalendarBusyBlock], in range: CalendarBusyBlock) throws -> [CalendarBusyBlock] {
        guard blocks.count <= maximumEvents else {
            throw AgentError("CALENDAR_LIMIT_EXCEEDED", "Too many calendar events. Request a smaller range; no partial free/busy result was returned.")
        }
        let sorted = blocks.compactMap { block -> CalendarBusyBlock? in
            let start = max(block.start, range.start), end = min(block.end, range.end)
            return end > start ? CalendarBusyBlock(start: start, end: end) : nil
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [CalendarBusyBlock] = []
        for block in sorted {
            if let last = merged.last, block.start <= last.end {
                merged[merged.count - 1].end = max(last.end, block.end)
            } else { merged.append(block) }
        }
        return merged
    }

    static func result(_ blocks: [CalendarBusyBlock], in range: CalendarBusyBlock) throws -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["after": formatter.string(from: range.start), "before": formatter.string(from: range.end),
                "busy": try merge(blocks, in: range).map { ["start": formatter.string(from: $0.start), "end": formatter.string(from: $0.end)] },
                "source": "eventkit", "scope": "own_calendar", "complete": true,
                "side_effects": false, "teammate_availability": "unknown"]
    }
}

enum CalendarFreeBusyReader {
    private static let queue = DispatchQueue(label: "com.muckstack.myman.freebusy", qos: .userInitiated)

    static func read(_ args: [String: Any]) async throws -> [String: Any] {
        let range = try CalendarFreeBusy.range(args)
        let blocks: [CalendarBusyBlock] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try load(range)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        return try CalendarFreeBusy.result(blocks, in: range)
    }

    /// Never request permission here. The human uses MyMan's existing OS
    /// permission screen, independently of the default-off calendar_read grant.
    static func load(_ range: CalendarBusyBlock) throws -> [CalendarBusyBlock] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AgentError("PERMISSION_REQUIRED", "Grant Calendar access using My Man's permission screen, and enable calendar_read in Settings → Agents.")
        }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil))
        guard events.count <= CalendarFreeBusy.maximumEvents else {
            throw AgentError("CALENDAR_LIMIT_EXCEEDED", "Too many calendar events. Request a smaller range; no partial result was returned.")
        }
        return events.compactMap { event in
            guard isBusy(status: event.status, availability: event.availability, declined: CalendarWatcher.isDeclined(event)),
                  let start = event.startDate, let end = event.endDate else { return nil }
            return CalendarBusyBlock(start: start, end: end)
        }
    }

    static func isBusy(status: EKEventStatus, availability: EKEventAvailability, declined: Bool) -> Bool {
        status != .canceled && availability != .free && !declined
    }
}
