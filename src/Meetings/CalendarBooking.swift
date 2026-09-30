import Foundation
import EventKit
import Combine

struct CalendarBookingDraft: Sendable, Equatable {
    let title: String
    let start: Date
    let duration: Int
    let zone: TimeZone
    let guests: [String]
    var end: Date { start.addingTimeInterval(Double(duration * 60)) }
    init(_ args: [String: Any], now: Date = Date()) throws {
        guard let start = (args["start"] as? String).flatMap(CalendarFreeBusy.instant), start > now else {
            throw AgentError("INVALID_ARGUMENTS", "Choose a future start time with an explicit UTC offset.")
        }
        let f = ISO8601DateFormatter()
        var proposal = args
        proposal["after"] = f.string(from: start)
        proposal["before"] = f.string(from: start.addingTimeInterval(86400))
        let request = try CalendarProposal.Request(proposal)
        title = request.title; duration = request.duration; zone = request.zone; guests = request.guests; self.start = start
    }
    var json: [String: Any] {
        let f = ISO8601DateFormatter()
        return ["title":title,"start":f.string(from:start),"end":f.string(from:end),"duration_minutes":duration,
                "time_zone":zone.identifier,"guests":guests,"guest_count":guests.count,
                "send_invitations":false,"video_link":NSNull(),"calendar_scope":"own_calendar"]
    }
}

/// One immutable preview. Only the native confirmation view calls bookFromHuman.
/// No CLI/MCP argument, confirmation token or polling action can invoke it.
@MainActor final class CalendarBookingSession: ObservableObject, Identifiable {
    enum State: String { case pending, saving, booked, cancelled, expired, failed }
    let id = UUID().uuidString
    let draft: CalendarBookingDraft
    let owner: AgentPrincipal?
    let expires: Date
    @Published private(set) var state = State.pending
    @Published private(set) var message: String?
    @Published private(set) var eventID: String?
    @Published var calendarID = ""
    let calendars: [(id: String, title: String)]
    private let now: () -> Date
    private let authorize: @MainActor () throws -> Void
    private let save: (CalendarBookingDraft, String) async throws -> String?

    init(draft: CalendarBookingDraft, owner: AgentPrincipal?, calendars: [(id:String,title:String)], defaultID: String,
         now: @escaping () -> Date = { Date() }, authorize: @escaping @MainActor () throws -> Void,
         save: @escaping (CalendarBookingDraft,String) async throws -> String?) {
        self.draft = draft; self.owner = owner; self.calendars = calendars; self.calendarID = defaultID
        self.now = now; expires = now().addingTimeInterval(600); self.authorize = authorize; self.save = save
    }
    func updateExpiry() { if state == .pending && now() >= expires { state = .expired; message = "This preview expired. Choose a time again." } }
    func cancel() { if state == .pending { state = .cancelled } }
    func receipt(for principal: AgentPrincipal) throws -> [String: Any] {
        guard owner?.id == principal.id else {
            throw AgentError("NOT_FOUND", "No booking request for this credential.")
        }
        return json
    }
    func bookFromHuman() async {
        updateExpiry()
        guard state == .pending else { return }
        do {
            try authorize()
            guard draft.start > now(), calendars.contains(where: { $0.id == calendarID }) else {
                throw AgentError("INVALID_ARGUMENTS", "Choose a future time and a writable calendar.")
            }
            state = .saving // Synchronous before awaiting: double presses cannot save twice.
            eventID = try await save(draft, calendarID)
            state = .booked
        } catch {
            state = .failed
            message = (error as? AgentError)?.message ?? "Couldn’t confirm the save. Check Calendar before trying again."
        }
    }
    var json: [String: Any] {
        updateExpiry()
        return ["request_id":id,"status":state == .pending ? "awaiting_human_confirmation" : state.rawValue,
                "preview":draft.json,"booked":state == .booked,"event_id":eventID as Any? ?? NSNull(),
                "expires_at":ISO8601DateFormatter().string(from:expires),"requires_human_book":true,
                "send_invitations":false,"message":message as Any? ?? NSNull()]
    }
}

/// EventKit is confined to one worker. Recheck busy time, owner grants and OS
/// access immediately before committing a fresh event without any attendees.
enum CalendarBookingWriter {
    struct Destinations: Sendable {
        let calendars: [(id:String,title:String)]
        let defaultID: String
    }
    private static let queue = DispatchQueue(label:"com.muckstack.myman.calendar-book",qos:.userInitiated)
    static func destinations() async throws -> Destinations {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try checkOwnerAndOS()
                    let store = EKEventStore()
                    let calendars = store.calendars(for:.event).filter { $0.allowsContentModifications && !$0.isSubscribed }
                    guard !calendars.isEmpty else { throw AgentError("NO_WRITABLE_CALENDAR","Add a writable calendar in Calendar first.") }
                    let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier ?? ""
                    continuation.resume(returning:Destinations(calendars:calendars.map { ($0.calendarIdentifier,$0.title) },defaultID:calendars.contains { $0.calendarIdentifier == defaultID } ? defaultID : calendars[0].calendarIdentifier))
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    static func save(_ draft: CalendarBookingDraft, calendarID: String, reauthorize: @escaping @MainActor @Sendable () throws -> Void) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try checkOwnerAndOS()
                    guard draft.start > Date() else { throw AgentError("PAST_TIME","That start time has passed. Choose another time.") }
                    let range = CalendarBusyBlock(start:draft.start,end:draft.end)
                    guard try CalendarFreeBusyReader.load(range).allSatisfy({ $0.end <= range.start || $0.start >= range.end }) else {
                        throw AgentError("CALENDAR_CONFLICT","Your calendar changed: that time is busy. Choose another time.")
                    }
                    let store = EKEventStore()
                    guard let calendar = store.calendar(withIdentifier:calendarID), calendar.allowsContentModifications, !calendar.isSubscribed else {
                        throw AgentError("NO_WRITABLE_CALENDAR","That calendar is no longer writable. Choose another calendar.")
                    }
                    let event = EKEvent(eventStore:store)
                    event.calendar = calendar; event.title = draft.title; event.startDate = draft.start; event.endDate = draft.end; event.timeZone = draft.zone
                    // Guest labels are context in your private event, never attendees.
                    if !draft.guests.isEmpty { event.notes = "Planned with: " + draft.guests.joined(separator:", ") + "\nNo invitations sent by My Man." }
                    try DispatchQueue.main.sync { try MainActor.assumeIsolated { try reauthorize() } }
                    try checkOwnerAndOS()
                    do { try store.save(event,span:.thisEvent,commit:true) }
                    catch { throw AgentError("CALENDAR_SAVE_FAILED","Calendar couldn’t confirm the save. Check Calendar before trying again.") }
                    continuation.resume(returning:event.eventIdentifier)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    private static func checkOwnerAndOS() throws {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey:"agentActionsEnabled") as? Bool ?? true,
              defaults.bool(forKey:"agentCalendarReadEnabled"), defaults.bool(forKey:"agentCalendarWriteEnabled") else {
            throw AgentError("AGENT_DISABLED","Enable calendar_read and calendar_write in My Man Settings → Agents.")
        }
        guard EKEventStore.authorizationStatus(for:.event) == .fullAccess else {
            throw AgentError("PERMISSION_REQUIRED","Grant Calendar access yourself in My Man’s permission screen.")
        }
    }
}

@MainActor final class CalendarBookingCenter {
    static let shared = CalendarBookingCenter()
    private var sessions: [String:CalendarBookingSession] = [:]
    private var preparing = false
    func present(_ args: [String:Any], owner: AgentPrincipal?) async throws -> [String:Any] {
        try Self.authorize(owner)
        let draft = try CalendarBookingDraft(args)
        sessions.values.forEach { $0.updateExpiry() }
        guard !preparing, !sessions.values.contains(where: { $0.state == .pending || $0.state == .saving }) else {
            throw AgentError("CONFIRMATION_PENDING","Finish or cancel the open calendar preview first.")
        }
        preparing = true; defer { preparing = false }
        let destinations = try await CalendarBookingWriter.destinations()
        try Self.authorize(owner)
        let session = CalendarBookingSession(draft:draft,owner:owner,calendars:destinations.calendars,defaultID:destinations.defaultID,
            authorize:{ try Self.authorize(owner) },save:{ draft, calendarID in
                try Self.authorize(owner)
                return try await CalendarBookingWriter.save(draft,calendarID:calendarID,reauthorize:{ try Self.authorize(owner) })
            })
        // Receipts are in-memory and scoped to their requesting credential.
        if sessions.count >= 100 { sessions.removeAll() }
        sessions[session.id] = session
        CalendarBookingWindow.shared.show(session)
        return session.json
    }
    func status(_ id: String, owner: AgentPrincipal) throws -> [String:Any] {
        try Self.authorize(owner)
        guard let session = sessions[id] else {
            throw AgentError("NOT_FOUND","No booking request for this credential. Previews expire and do not survive app restarts.")
        }
        return try session.receipt(for: owner)
    }
    private static func authorize(_ owner: AgentPrincipal?) throws {
        try AgentConsent.validate("calendar.book",args:[:])
        if let owner { try AgentIdentity.shared.validate(owner,action:"calendar.book") }
    }
}
