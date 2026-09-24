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
            let id = timer.addTimer(seconds: args["seconds"] as! Double, soundEnabled: args["sound_enabled"] as? Bool ?? true, owner: owner)
            return timerStatus(timer, id: id)
        case "timer.status":
            var result = timerStatus(timer, id: timer.timerID)
            result["timers"] = timer.timers.map { timerJSON($0) }
            return result
        case "timer.pause", "timer.resume", "timer.cancel", "timer.sound":
            guard let id = args["session_id"] as? String, let current = timer.timer(id) else {
                throw AgentError("SESSION_MISMATCH", "This timer is no longer active. Inspect timer.status.")
            }
            guard current.agentOwner == owner else { throw AgentError("NOT_OWNER", "Only the timer’s creating agent or human controls can change it.") }
            if action == "timer.cancel" { timer.stop(id) }
            else if action == "timer.sound" { timer.setSound(args["enabled"] as! Bool, id: id) }
            else if action == "timer.pause" { timer.pause(id) }
            else { timer.resume(id) }
            return timerStatus(timer, id: id)
        case "reminder.create":
            guard (args["seconds"] != nil) != (args["at"] != nil) else {
                throw AgentError("INVALID_ARGUMENTS", "Provide seconds or at, not both.")
            }
            let date: Date
            if let seconds = args["seconds"] as? Double { date = Date().addingTimeInterval(seconds) }
            else if let parsed = timestamp(args["at"] as? String ?? "") { date = parsed }
            else { throw AgentError("INVALID_ARGUMENTS", "at must be an ISO 8601 timestamp with a time-zone offset.") }
            return reminderJSON(try await reminders.create(.init(title: args["message"] as! String, date: date), owner: owner, soundEnabled: args["sound_enabled"] as? Bool ?? true))
        case "reminder.list": return ["reminders": reminders.reminders.map(reminderJSON)]
        case "reminder.cancel", "reminder.sound":
            guard let reminder = reminders.reminders.first(where: { $0.id.uuidString == args["id"] as? String }) else {
                throw AgentError("NOT_FOUND", "Reminder not found.")
            }
            guard reminder.agentOwner == owner else { throw AgentError("NOT_OWNER", "Only the reminder’s creating agent or human controls can dismiss it.") }
            if action == "reminder.sound" {
                return reminderJSON(try await reminders.setSoundEnabled(args["enabled"] as! Bool, for: reminder.id))
            }
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

    static func timerStatus(_ timer: QuickToolsModel, id: String?) -> [String: Any] {
        var result: [String: Any] = ["requires_app_open": true, "active_count": timer.timers.count]
        guard let id, let current = timer.timer(id) else {
            result["active"] = false; result["state"] = "idle"; result["remaining_seconds"] = 0
            return result
        }
        return result.merging(timerJSON(current)) { $1 }
    }

    static func timerJSON(_ timer: QuickTimer) -> [String: Any] {
        var result: [String: Any] = ["active": true, "session_id": timer.id, "state": timer.state,
                                     "sound_enabled": timer.soundEnabled, "duration_seconds": timer.duration,
                                     "remaining_seconds": timer.remaining(at: Date())]
        if let deadline = timer.deadline { result["deadline"] = ISO8601DateFormatter().string(from: deadline) }
        return result
    }

    static func reminderJSON(_ reminder: LocalReminder) -> [String: Any] {
        ["id": reminder.id.uuidString, "message": reminder.title,
         "at": ISO8601DateFormatter().string(from: reminder.date), "due": reminder.fired || reminder.date <= Date(),
         "notification_scheduled": reminder.notificationScheduled, "requires_app_open": !reminder.notificationScheduled,
         "sound_enabled": reminder.playsSound]
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
