import AppKit
import AVFoundation
import Foundation
import UserNotifications

@MainActor enum QuickCompletionSound {
    private static var player: AVAudioPlayer?
    static var isPlaying: Bool { player?.isPlaying == true }

    /// Use the normal audio output, retain playback, and check failures instead
    /// of silently relying on the system alert-sound name and alert volume.
    @discardableResult static func play() -> Bool {
        player?.stop()
        do {
            guard let folder = Bundle.module.url(forResource: "Sounds", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            let next = try AVAudioPlayer(contentsOf: folder.appendingPathComponent("reminder-chime.wav"))
            next.volume = 1
            next.prepareToPlay()
            player = next
            if next.play() { return true }
        } catch { }
        NSSound.beep()
        return false
    }
}

enum QuickTimerRequest {
    static func commandText(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?"#, with: "", options: .regularExpression)
    }

    static func messageReminder(_ input: String, now: Date) -> ReminderDraft? {
        let text = commandText(input)
        let prefix = #"(?i)^(?:(?:set|start)\s+(?:me\s+)?(?:a\s+)?)?timer(?:\s+for)?\s+"#
        guard let range = text.range(of: prefix, options: .regularExpression) else { return nil }
        let body = String(text[range.upperBound...])
        let pattern = #"(?i)^(.+?)\s+(?:to remind me to|to remind me about|to remind me|for|to)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let durationRange = Range(match.range(at: 1), in: body), let titleRange = Range(match.range(at: 2), in: body),
              let seconds = QuickToolParser.duration(String(body[durationRange])) else { return nil }
        return ReminderDraft(title: String(body[titleRange]), date: now.addingTimeInterval(seconds))
    }
}

struct ReminderDraft: Equatable {
    var title: String
    var date: Date
    /// Editor defaults are useful previews, but must not auto-submit as spoken deadlines.
    var hasExplicitTime = true

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDraft? {
        if let timer = QuickTimerRequest.messageReminder(input, now: now) { return timer }
        let text = QuickTimerRequest.commandText(input)
        let prefix = #"(?i)^(?:remind me(?: to)?|(?:(?:set|create)\s+(?:a\s+)?)?reminder(?: to)?)(?:\s+|$)"#
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
        return Self(title: body, date: now.addingTimeInterval(3_600), hasExplicitTime: false)
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
    var agentOwner: String? = nil
    var fired = false
    var notificationScheduled = false
    // Optional on disk so reminders saved before this setting still decode.
    var soundEnabled: Bool? = nil
    var playsSound: Bool { soundEnabled ?? true }
    var notificationID: String { "myman.reminder." + id.uuidString }
}

@MainActor final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()
    @Published private(set) var reminders: [LocalReminder]
    private let defaults: UserDefaults
    private let schedule: @MainActor (LocalReminder) async -> Bool
    private let cancelNotification: @MainActor (String) -> Void
    private let alert: @MainActor () -> Void
    private let notificationSoundsEnabled: @MainActor () async -> Bool
    private var notificationTasks: [UUID: Task<Bool, Never>] = [:]
    private var notificationGenerations: [UUID: UUID] = [:]
    private static let key = "localReminders.v1"

    init(defaults: UserDefaults = .standard,
         schedule: (@MainActor (LocalReminder) async -> Bool)? = nil,
         cancelNotification: (@MainActor (String) -> Void)? = nil,
         alert: @escaping @MainActor () -> Void = { QuickCompletionSound.play() },
         notificationSoundsEnabled: (@MainActor () async -> Bool)? = nil) {
        self.defaults = defaults
        self.schedule = schedule ?? Self.scheduleNotification
        self.cancelNotification = cancelNotification ?? Self.cancelNotification
        self.alert = alert
        self.notificationSoundsEnabled = notificationSoundsEnabled ?? {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
            return await UNUserNotificationCenter.current().notificationSettings().soundSetting == .enabled
        }
        reminders = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LocalReminder].self, from: $0) } ?? []
    }

    @discardableResult func add(_ draft: ReminderDraft, now: Date = Date()) async -> String {
        do {
            let reminder = try await create(draft, now: now)
            return reminder.notificationScheduled ? "Reminder set" : "Reminder set. Keep My Man open, or enable notifications for alerts while it’s closed."
        } catch { return error.localizedDescription }
    }

    func create(_ draft: ReminderDraft, owner: String? = nil, soundEnabled: Bool = true, waitForNotification: Bool = true, now: Date = Date()) async throws -> LocalReminder {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500 else { throw AgentError("INVALID_ARGUMENTS", "Add a reminder title of 1–500 characters.") }
        guard draft.date > now else { throw AgentError("INVALID_ARGUMENTS", "Choose a future time.") }
        guard reminders.count < 32 else { throw AgentError("LIMIT_REACHED", "Dismiss a reminder before adding another.") }
        let reminder = LocalReminder(id: UUID(), title: title, date: draft.date, agentOwner: owner, soundEnabled: soundEnabled)
        reminders.append(reminder)
        persist()
        if !waitForNotification {
            Task { await refreshNotification(reminder.id) }
            return reminder
        }
        await refreshNotification(reminder.id)
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else {
            throw AgentError("CANCELLED", "Reminder dismissed")
        }
        return reminders[index]
    }

    @discardableResult func setSoundEnabled(_ enabled: Bool, for id: UUID) async throws -> LocalReminder {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { throw AgentError("NOT_FOUND", "Reminder not found.") }
        reminders[index].soundEnabled = enabled
        reminders[index].notificationScheduled = false
        cancelNotification(reminders[index].notificationID)
        persist()
        await refreshNotification(id)
        guard let updated = reminders.first(where: { $0.id == id }) else { throw AgentError("CANCELLED", "Reminder dismissed") }
        return updated
    }

    /// Serialize replacement requests so an older permission/schedule callback
    /// cannot restore a sound after mute or resurrect a dismissed reminder.
    private func refreshNotification(_ id: UUID) async {
        let previous = notificationTasks[id]
        let generation = UUID()
        notificationGenerations[id] = generation
        let task = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self, self.notificationGenerations[id] == generation,
                  let reminder = self.reminders.first(where: { $0.id == id }), !reminder.fired, reminder.date > Date() else { return false }
            let scheduled = await self.schedule(reminder)
            guard self.notificationGenerations[id] == generation, self.reminders.contains(where: { $0.id == id }) else {
                self.cancelNotification(reminder.notificationID)
                return false
            }
            return scheduled
        }
        notificationTasks[id] = task
        let scheduled = await task.value
        guard notificationGenerations[id] == generation else { return }
        notificationTasks[id] = nil
        notificationGenerations[id] = nil
        if let index = reminders.firstIndex(where: { $0.id == id }) {
            reminders[index].notificationScheduled = scheduled
            persist()
        }
    }

    func dismiss(_ id: UUID) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        reminders.removeAll { $0.id == id }
        notificationGenerations[id] = nil
        notificationTasks[id] = nil
        cancelNotification(reminder.notificationID)
        persist()
    }

    func tick(now: Date = Date()) {
        var changed = false
        var shouldAlert = false
        var scheduledSoundIDs: [UUID] = []
        for index in reminders.indices where !reminders[index].fired && reminders[index].date <= now {
            reminders[index].fired = true
            if reminders[index].playsSound {
                if reminders[index].notificationScheduled { scheduledSoundIDs.append(reminders[index].id) }
                else { shouldAlert = true }
            }
            changed = true
        }
        if changed { persist() }
        if shouldAlert { alert() }
        else if !scheduledSoundIDs.isEmpty {
            // Notification permission does not imply permission for its sound.
            let dueIDs = Set(scheduledSoundIDs)
            Task { [weak self] in
                guard let self, !(await self.notificationSoundsEnabled()),
                      self.reminders.contains(where: { dueIDs.contains($0.id) && $0.playsSound }) else { return }
                self.alert()
            }
        }
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
            guard reminder.date > Date() else { return false }
            content.sound = reminder.playsSound ? .default : nil
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
