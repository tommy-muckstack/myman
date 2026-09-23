import AppKit
import Foundation
import UserNotifications

struct ReminderDraft: Equatable {
    var title: String
    var date: Date

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDraft? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"(?i)^(?:remind me(?: to)?|reminder(?: to)?)(?:\s+|$)"#
        guard let range = text.range(of: prefix, options: .regularExpression) else { return nil }
        let body = String(text[range.upperBound...])
        if let parts = groups(#"(?i)^in\s+(.+?)\s+(?:for|to)\s+(.+)$"#, body),
           case .timer(let seconds) = QuickToolParser.parse("timer " + parts[1]) {
            return Self(title: parts[2], date: now.addingTimeInterval(seconds))
        }
        if let parts = groups(#"(?i)^(.+?)\s+in\s+(.+)$"#, body),
           case .timer(let seconds) = QuickToolParser.parse("timer " + parts[2]) {
            return Self(title: parts[1], date: now.addingTimeInterval(seconds))
        }
        if let parts = groups(#"(?i)^(.+?)\s+(?:(today|tomorrow)\s+)?at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, body),
           var hour = Int(parts[3]), let minute = Int(parts[4].isEmpty ? "0" : parts[4]), minute < 60,
           parts[5].isEmpty ? (0...23).contains(hour) : (1...12).contains(hour) {
            if !parts[5].isEmpty { hour = hour % 12 + (parts[5].lowercased() == "pm" ? 12 : 0) }
            let day = calendar.date(byAdding: .day, value: parts[2].lowercased() == "tomorrow" ? 1 : 0, to: now) ?? now
            if var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
                if date <= now, parts[2].isEmpty { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
                return Self(title: parts[1], date: date)
            }
        }
        return Self(title: body, date: now.addingTimeInterval(3_600))
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

struct LocalReminder: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let date: Date
    var fired = false
    var notificationScheduled = false
    var notificationID: String { "myman.reminder." + id.uuidString }
}

@MainActor final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
    @Published private(set) var reminders: [LocalReminder]
    private let defaults: UserDefaults
    private let schedule: @MainActor (LocalReminder) async -> Bool
    private let cancelNotification: @MainActor (String) -> Void
    private let alert: @MainActor () -> Void
    private static let key = "localReminders.v1"

    init(defaults: UserDefaults = .standard,
         schedule: (@MainActor (LocalReminder) async -> Bool)? = nil,
         cancelNotification: (@MainActor (String) -> Void)? = nil,
         alert: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        self.defaults = defaults
        self.schedule = schedule ?? Self.scheduleNotification
        self.cancelNotification = cancelNotification ?? Self.cancelNotification
        self.alert = alert
        reminders = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LocalReminder].self, from: $0) } ?? []
    }

    @discardableResult func add(_ draft: ReminderDraft, now: Date = Date()) async -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Add a reminder title." }
        guard draft.date > now else { return "Choose a future time." }
        guard reminders.count < 32 else { return "Dismiss a reminder before adding another." }
        let reminder = LocalReminder(id: UUID(), title: title, date: draft.date)
        reminders.append(reminder)
        persist()
        let scheduled = await schedule(reminder)
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else {
            cancelNotification(reminder.notificationID)
            return "Reminder dismissed"
        }
        reminders[index].notificationScheduled = scheduled
        persist()
        return scheduled ? "Reminder set" : "Reminder set. Keep My Man open, or enable notifications for alerts while it’s closed."
    }

    func dismiss(_ id: UUID) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        reminders.removeAll { $0.id == id }
        cancelNotification(reminder.notificationID)
        persist()
    }

    func tick(now: Date = Date()) {
        var changed = false
        var shouldAlert = false
        for index in reminders.indices where !reminders[index].fired && reminders[index].date <= now {
            reminders[index].fired = true
            shouldAlert = shouldAlert || !reminders[index].notificationScheduled
            changed = true
        }
        if changed { persist() }
        if shouldAlert { alert() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reminders) { defaults.set(data, forKey: Self.key) }
    }

    static func configureNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().delegate = ReminderNotificationDelegate.shared
    }

    private static func scheduleNotification(_ reminder: LocalReminder) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        center.delegate = ReminderNotificationDelegate.shared
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return false }
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = reminder.title
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: reminder.notificationID, content: content, trigger: trigger))
            return true
        } catch { return false }
    }

    private static func cancelNotification(_ id: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

private final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
