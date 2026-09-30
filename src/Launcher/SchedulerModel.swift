import Foundation
import Combine

/// UI state only. Edits invalidate selection; reads use the same owner grants
/// as CLI/MCP. No network, calendar writes or invitation recipients.
@MainActor final class SchedulerModel: ObservableObject {
    @Published var title = "Meeting"
    @Published var day = Date()
    @Published var duration = 30
    @Published var people: [String] = []
    @Published var matches: [PeopleResolution.Match] = []
    @Published var busy: [CalendarBusyBlock] = []
    @Published var slots: [Date] = []
    @Published var selected: Date?
    @Published var loading = false
    @Published var message: String?
    @Published var needsOSPermission = false
    @Published var needsGrants = false
    @Published var hasAvailability = false
    @Published var clarification: String?
    let zone: TimeZone
    private var revision = 0
    private let now: () -> Date
    private let authorize: @MainActor (String) throws -> Void
    private let read: ([String: Any]) async throws -> [String: Any]
    private let resolve: ([String]) async throws -> [PeopleResolution.Match]

    init(zone: TimeZone = .current, now: @escaping () -> Date = { Date() },
         authorize: @escaping @MainActor (String) throws -> Void = { try AgentConsent.validate($0, args: [:]) },
         read: @escaping ([String: Any]) async throws -> [String: Any] = { try await CalendarFreeBusyReader.read($0) },
         resolve: @escaping ([String]) async throws -> [PeopleResolution.Match] = { names in
             try await Task.detached { try PeopleResolution.resolve(names: names, records: People.resolutionRecords()) }.value
         }) {
        self.zone = zone; self.now = now; self.authorize = authorize; self.read = read; self.resolve = resolve
    }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    var end: Date? { selected?.addingTimeInterval(Double(duration * 60)) }
    var canReview: Bool { hasAvailability && selected != nil && !loading && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var dateRange: CalendarBusyBlock {
        let start = calendar.startOfDay(for: day)
        return .init(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    func date(at minutes: Int) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)!
    }
    func time(_ date: Date) -> String { format(date, "h:mm a") }
    func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = .current; f.timeZone = zone; f.dateFormat = pattern; return f.string(from: date)
    }
    nonisolated static func recognizes(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (recognizesCreation(text) || text.range(of: #"^(?:(?:please\s+)?(?:schedule|book|arrange|set up)\b|(?:meeting|coffee|lunch|catch up|catch-up|call|dinner)\s+with\b)"#, options: [.regularExpression, .caseInsensitive]) != nil)
            && LauncherCalendarRequest.parse(text) == nil
    }
    private nonisolated static func recognizesCreation(_ input: String) -> Bool {
        // Creation verbs alone still belong to notes. Match a calendar object,
        // while keeping requests for meeting notes, call scripts, etc. as notes.
        input.range(of: #"^\s*(?:please\s+)?(?:create|make|new)\s+(?:an?\s+)?(?:new\s+)?(?:(?:(?:video|phone|conference)\s+)?call|meeting|appointment|(?:calendar\s+)?event|calendar\s+(?:invite|invitation))\b(?!\s+(?:(?:invite|invitation)\s+)?(?:notes?|checklist|summary|transcript|recording|agenda|template|log|script)\b)"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
    nonisolated static func schedulingText(_ input: String) -> String {
        guard recognizesCreation(input) else { return input }
        return input.replacingOccurrences(of: #"^\s*(?:please\s+)?(?:create|make|new)\s+(?:an?\s+)?(?:new\s+)?"#,
                                          with: "", options: [.regularExpression, .caseInsensitive])
    }
    func invalidate() {
        revision += 1; loading = false; hasAvailability = false; selected = nil; slots = []; busy = []; message = nil
    }
    func load(_ input: String) async {
        invalidate(); matches = []; people = []; needsGrants = false; needsOSPermission = false; clarification = nil
        let version = revision
        do {
            try authorize("scheduling.parse")
            guard input.count <= SchedulingIntentParser.maximumInputLength else { throw AgentError("INVALID_ARGUMENTS", "Keep the meeting request under 2,000 characters.") }
            let parsed = await SchedulingIntentService.parse(Self.schedulingText(input), reference: now(), timeZone: zone)
            guard version == revision, !Task.isCancelled else { return }
            let intent = parsed.intent
            title = intent.title ?? "Meeting"; people = Array(intent.people.prefix(20)); duration = intent.durationMinutes ?? 30
            if !(1...480).contains(duration) { duration = 30 }
            day = now()
            if let value = intent.day {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
                day = f.date(from: value) ?? day
            }
            if !intent.issues.isEmpty { clarification = "A few details were unclear. Check the title, date and time below." }
            var preferred: Date?
            if let time = intent.time {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { preferred = date(at: parts[0] * 60 + parts[1]) }
            }
            if !people.isEmpty, (try? authorize("people.resolve")) != nil {
                let resolved = try? await resolve(people)
                guard version == revision, !Task.isCancelled else { return }
                matches = resolved ?? []
            }
            await refresh(preferred: preferred)
        } catch { show(error) }
    }
    func refresh(preferred: Date? = nil) async {
        invalidate(); let version = revision
        loading = true; needsGrants = false; needsOSPermission = false
        defer { if version == revision { loading = false } }
        do {
            try authorize("calendar.propose")
            let f = ISO8601DateFormatter(), range = dateRange
            let args: [String: Any] = ["after": f.string(from: range.start), "before": f.string(from: range.end),
                "title": title.isEmpty ? "Meeting" : title, "time_zone": zone.identifier == "GMT" ? "UTC" : zone.identifier,
                "duration_minutes": duration, "guests": people, "limit": 5]
            let availability = try await read(args)
            guard version == revision, !Task.isCancelled else { return }
            try authorize("calendar.propose") // Revocation while reading takes effect.
            let proposal = try CalendarProposal.result(try .init(args), availability: availability, now: now())
            busy = (availability["busy"] as? [[String: String]] ?? []).compactMap { block in
                guard let a = block["start"].flatMap(CalendarFreeBusy.instant), let b = block["end"].flatMap(CalendarFreeBusy.instant) else { return nil }
                return .init(start: a, end: b)
            }
            slots = (proposal["slots"] as? [[String: String]] ?? []).compactMap { $0["start"].flatMap(CalendarFreeBusy.instant) }
            hasAvailability = true
            if let preferred { select(preferred) }
            else { selected = slots.first }
            if slots.isEmpty && selected == nil { message = "No free times in the 9–6 window. Try another day or choose a time." }
        } catch { if version == revision { show(error) } }
    }
    func select(_ start: Date) {
        selected = nil; message = nil
        let end = start.addingTimeInterval(Double(duration * 60)), range = dateRange
        guard hasAvailability, start >= now(), start >= range.start, end <= range.end,
              !busy.contains(where: { start < $0.end && end > $0.start }) else {
            message = "That time is unavailable. Choose a future time without a calendar conflict."; return
        }
        selected = start
    }
    func choose(_ candidate: PeopleResolution.Candidate, for index: Int) {
        guard people.indices.contains(index) else { return }
        people[index] = candidate.name // Display only; never an attendee address.
    }
    private func show(_ error: Error) {
        let error = error as? AgentError
        needsGrants = error?.code == "AGENT_DISABLED"
        needsOSPermission = error?.code == "PERMISSION_REQUIRED"
        message = needsGrants ? "Choose your scheduling permissions to see available times." : needsOSPermission ? "Allow Calendar access to check your availability." : "Couldn’t read availability. Try again or check your calendar settings."
    }
}
