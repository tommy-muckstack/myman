import EventKit
import Foundation

@MainActor enum AgentQuickTools {
    static func execute(_ action: String, _ args: [String: Any],
                        timer suppliedTimer: QuickToolsModel? = nil, reminders suppliedReminders: ReminderStore? = nil,
                        owner: String = AgentContext.principal.id) async throws -> [String: Any] {
        let timer = suppliedTimer ?? QuickToolsController.shared.model
        let reminders = suppliedReminders ?? ReminderStore.shared
        switch action {
        case "tool.evaluate": return evaluate(args["input"] as! String)
        case "timer.start":
            guard !timer.timerActive else { throw AgentError("BUSY", "A timer already exists. Inspect timer.status before changing it.") }
            timer.start(seconds: args["seconds"] as! Double)
            timer.timerAgentOwner = owner
            return timerStatus(timer)
        case "timer.status": return timerStatus(timer)
        case "timer.pause", "timer.resume", "timer.cancel":
            guard timer.timerActive, args["session_id"] as? String == timer.timerID else {
                throw AgentError("SESSION_MISMATCH", "This timer is no longer active. Inspect timer.status.")
            }
            guard timer.timerAgentOwner == owner else { throw AgentError("NOT_OWNER", "Only the timer’s creating agent or human controls can change it.") }
            if action == "timer.cancel" { timer.stop() }
            else if action == "timer.pause" { timer.pause() }
            else if let seconds = timer.pausedSeconds { timer.start(seconds: seconds) }
            return timerStatus(timer)
        case "reminder.create":
            guard (args["seconds"] != nil) != (args["at"] != nil) else {
                throw AgentError("INVALID_ARGUMENTS", "Provide seconds or at, not both.")
            }
            let date: Date
            if let seconds = args["seconds"] as? Double { date = Date().addingTimeInterval(seconds) }
            else if let parsed = timestamp(args["at"] as? String ?? "") { date = parsed }
            else { throw AgentError("INVALID_ARGUMENTS", "at must be an ISO 8601 timestamp with a time-zone offset.") }
            return reminderJSON(try await reminders.create(.init(title: args["message"] as! String, date: date), owner: owner))
        case "reminder.list": return ["reminders": reminders.reminders.map(reminderJSON)]
        case "reminder.cancel":
            guard let reminder = reminders.reminders.first(where: { $0.id.uuidString == args["id"] as? String }) else {
                throw AgentError("NOT_FOUND", "Reminder not found.")
            }
            guard reminder.agentOwner == owner else { throw AgentError("NOT_OWNER", "Only the reminder’s creating agent or human controls can dismiss it.") }
            reminders.dismiss(reminder.id)
            return ["dismissed": reminder.id.uuidString]
        case "calendar.list":
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw AgentError("PERMISSION_REQUIRED", "Allow Calendar access in My Man settings.") }
            let formatter = ISO8601DateFormatter()
            guard let start = timestamp(args["after"] as? String ?? ""),
                  let end = timestamp(args["before"] as? String ?? ""),
                  end > start, end.timeIntervalSince(start) <= 31 * 86400 else {
                throw AgentError("INVALID_ARGUMENTS", "Provide ISO 8601 after/before timestamps spanning at most 31 days.")
            }
            let store = EKEventStore()
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
            return ["events": events.prefix(500).map { event in
                ["id": event.eventIdentifier ?? "", "title": event.title ?? "Untitled",
                 "start": formatter.string(from: event.startDate), "end": formatter.string(from: event.endDate),
                 "all_day": event.isAllDay, "calendar": event.calendar.title] as [String: Any]
            }, "partial": events.count > 500]
        default: throw AgentError("UNKNOWN_ACTION", "Unknown quick tool action.")
        }
    }

    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func timerStatus(_ timer: QuickToolsModel) -> [String: Any] {
        var result: [String: Any] = ["active": timer.timerActive, "state": timer.finished ? "finished" : timer.pausedSeconds != nil ? "paused" : timer.deadline != nil ? "running" : "idle",
                                  "requires_app_open": true]
        if let id = timer.timerID { result["session_id"] = id }
        if let deadline = timer.deadline { result["deadline"] = ISO8601DateFormatter().string(from: deadline) }
        result["remaining_seconds"] = max(0, timer.deadline?.timeIntervalSinceNow ?? timer.pausedSeconds ?? 0)
        return result
    }

    static func reminderJSON(_ reminder: LocalReminder) -> [String: Any] {
        ["id": reminder.id.uuidString, "message": reminder.title,
         "at": ISO8601DateFormatter().string(from: reminder.date), "due": reminder.fired || reminder.date <= Date(),
         "notification_scheduled": reminder.notificationScheduled, "requires_app_open": !reminder.notificationScheduled]
    }

    static func evaluate(_ input: String) -> [String: Any] {
        let tool = QuickToolParser.parse(input)
        var result: [String: Any] = ["kind": tool.title, "markdown": tool.markdown(), "side_effects": false]
        switch tool {
        case .calculation(_, let value): result["value"] = value
        case .conversion(_, let value, let unit): result["value"] = value; result["unit"] = unit
        case .color(let hex): result["hex"] = hex; result["palette"] = QuickColorPalette.companions(for: hex)
        case .timeZone(let value):
            result["instant"] = ISO8601DateFormatter().string(from: value.date)
            result["source_zone"] = value.source.identifier; result["destination_zone"] = value.destination.identifier
        case .timer(let seconds): result["seconds"] = seconds; result["start_action"] = "timer.start"
        case .reminder(let value):
            result["message"] = value.title; result["at"] = ISO8601DateFormatter().string(from: value.date); result["start_action"] = "reminder.create"
        case .checklist(let items): result["items"] = items
        case .split(let cents, let people, let currency): result["cents"] = cents; result["people"] = people; result["currency"] = currency
        case .incomplete: result["valid"] = false
        default: break
        }
        return result
    }
}
