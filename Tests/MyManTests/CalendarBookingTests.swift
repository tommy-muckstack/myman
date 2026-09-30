import XCTest
@testable import MyMan

final class CalendarBookingTests: XCTestCase {
    private let now = CalendarFreeBusy.instant("2026-09-30T08:00:00Z")!
    private var args: [String:Any] { ["title":"Coffee","start":"2026-10-01T10:00:00Z","time_zone":"UTC","duration_minutes":30,"guests":["Mary"]] }
    @MainActor func testPreviewAndPollingNeverWriteAndHumanPressIsSingleUse() async throws {
        var writes = 0
        let session = CalendarBookingSession(draft:try .init(args,now:now),owner:nil,calendars:[("own","My calendar")],defaultID:"own",now:{ self.now },authorize:{},save:{ _, _ in writes += 1;await Task.yield();return "fixture-event" })
        XCTAssertEqual(session.json["status"] as? String,"awaiting_human_confirmation")
        for _ in 0..<3 { _ = session.json };XCTAssertEqual(writes,0)
        let first = Task { await session.bookFromHuman() }
        await Task.yield();await session.bookFromHuman();await first.value
        XCTAssertEqual(writes,1);XCTAssertEqual(session.state,.booked)
        XCTAssertEqual(session.json["send_invitations"] as? Bool,false)
        XCTAssertEqual(session.eventID,"fixture-event")
    }
    @MainActor func testCancelExpiryAndRevocationPreventWrites() async throws {
        var writes = 0, clock = now, allowed = true
        func session() throws -> CalendarBookingSession {
            CalendarBookingSession(draft:try .init(args,now:now),owner:nil,calendars:[("own","My calendar")],defaultID:"own",now:{ clock },authorize:{ if !allowed { throw AgentError("AGENT_DISABLED","Revoked") } },save:{ _,_ in writes += 1;return "event" })
        }
        let cancelled = try session();cancelled.cancel();await cancelled.bookFromHuman();XCTAssertEqual(cancelled.state,.cancelled)
        let expired = try session();clock = clock.addingTimeInterval(601);await expired.bookFromHuman();XCTAssertEqual(expired.state,.expired)
        let revoked = try session();allowed = false;await revoked.bookFromHuman();XCTAssertEqual(revoked.state,.failed)
        XCTAssertEqual(writes,0)
    }
    @MainActor func testFailedSaveCannotBeReplayedAndNilEventIDIsStillSuccess() async throws {
        var attempts = 0
        let draft = try CalendarBookingDraft(args,now:now)
        let failed = CalendarBookingSession(draft:draft,owner:nil,calendars:[("own","Mine")],defaultID:"own",now:{ self.now },authorize:{},save:{ _,_ in attempts += 1;throw AgentError("CALENDAR_CONFLICT","Busy") })
        await failed.bookFromHuman();await failed.bookFromHuman();XCTAssertEqual(attempts,1);XCTAssertEqual(failed.state,.failed)
        let success = CalendarBookingSession(draft:draft,owner:nil,calendars:[("own","Mine")],defaultID:"own",now:{ self.now },authorize:{},save:{ _,_ in nil })
        await success.bookFromHuman();XCTAssertEqual(success.state,.booked)
    }
    @MainActor func testWriteGrantIsDefaultOffAndStrictSchemaHasNoRemoteConfirmation() throws {
        let suite = "BookingTests-"+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"agentCalendarReadEnabled")
        XCTAssertEqual(AgentConsent.status(defaults)["calendar_write"],false)
        XCTAssertThrowsError(try AgentConsent.validate("calendar.book",args:args,defaults:defaults))
        defaults.set(true,forKey:"agentCalendarWriteEnabled")
        XCTAssertNoThrow(try AgentConsent.validate("calendar.book",args:args,defaults:defaults))
        defaults.set(false,forKey:"agentCalendarReadEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("calendar.book",args:args,defaults:defaults))
        let actions = AgentActions.catalog["actions"] as! [[String:Any]]
        let schema = actions.first { $0["name"] as? String == "calendar.book" }!["inputSchema"] as! [String:Any]
        XCTAssertNoThrow(try AgentSchema.validate(args,schema:schema))
        for key in ["confirm","approved","token","send_invitations","calendar_id","attendees","video_link"] {
            XCTAssertThrowsError(try AgentSchema.validate(args.merging([key:true]) { _,new in new },schema:schema))
        }
        let settings = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String:Any]
        XCTAssertThrowsError(try AgentSchema.validate(["agentCalendarWriteEnabled":true],schema:settings))
    }
    func testBookingRequiresFutureTimeAndValidDetails() throws {
        for patch: [String:Any] in [["title":""],["duration_minutes":0],["duration_minutes":481],["start":"2026-09-29T12:00:00Z"],["start":"2026-10-01T10:00:00"],["time_zone":"Unknown/Place"]] {
            XCTAssertThrowsError(try CalendarBookingDraft(args.merging(patch) { _,new in new },now:now))
        }
    }
    @MainActor func testNamedScopeRevocationAndReceiptOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identities = AgentIdentity(root: root)
        let (registration, token) = try identities.issue(name: "Planner", scopes: ["calendar_read", "calendar_write"])
        let owner = try identities.authenticate(["credential": token])
        let (_, readToken) = try identities.issue(name: "Reader", scopes: ["calendar_read"])
        let reader = try identities.authenticate(["credential": readToken])
        XCTAssertThrowsError(try identities.validate(reader, action: "calendar.book"))
        var writes = 0
        let session = CalendarBookingSession(draft: try .init(args, now: now), owner: owner,
            calendars: [("own", "Mine")], defaultID: "own", now: { self.now },
            authorize: { try identities.validate(owner, action: "calendar.book") },
            save: { _, _ in writes += 1; return "event" })
        XCTAssertNoThrow(try session.receipt(for: owner))
        XCTAssertThrowsError(try session.receipt(for: reader))
        XCTAssertThrowsError(try session.receipt(for: .local))
        try identities.revoke(registration.id)
        await session.bookFromHuman()
        XCTAssertEqual(writes, 0); XCTAssertEqual(session.state, .failed)
    }
    @MainActor func testChangedDestinationAndPassedStartFailClosed() async throws {
        var clock = now, writes = 0
        func session() throws -> CalendarBookingSession {
            CalendarBookingSession(draft: try .init(args, now: now), owner: nil,
                calendars: [("own", "Mine")], defaultID: "own", now: { clock }, authorize: {},
                save: { _, _ in writes += 1; return "event" })
        }
        let invalid = try session(); invalid.calendarID = "unknown"
        await invalid.bookFromHuman(); XCTAssertEqual(invalid.state, .failed)
        clock = CalendarFreeBusy.instant("2026-10-01T09:59:59Z")!
        let passed = try session(); clock = clock.addingTimeInterval(2)
        await passed.bookFromHuman(); XCTAssertEqual(passed.state, .failed)
        XCTAssertEqual(writes, 0)
    }
}
