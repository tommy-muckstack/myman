import XCTest
@testable import MyMan

final class CalendarProposalTests: XCTestCase {
    private var args: [String: Any] { ["title":"Coffee", "after":"2026-09-29T09:00:00Z", "before":"2026-09-29T11:00:00Z", "time_zone":"UTC"] }

    func testSharedSlotFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/calendar-proposal.json")
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for fixture in fixtures {
            let name = fixture["name"] as! String, args = fixture["args"] as! [String: Any]
            let request = try CalendarProposal.Request(args)
            let availability: [String: Any] = ["complete":true, "scope":"own_calendar", "busy":fixture["busy"]!]
            let result = try CalendarProposal.result(request, availability:availability, now:CalendarFreeBusy.instant(fixture["now"] as! String)!)
            let slots = result["slots"] as! [[String:String]], preview = result["preview"] as! [String:Any]
            XCTAssertEqual(slots.map { $0["start"]! },fixture["starts"] as! [String],name)
            XCTAssertEqual(result["candidate_count"] as? Int,fixture["count"] as? Int,name)
            XCTAssertEqual(result["truncated"] as? Bool,(fixture["count"] as! Int) > request.limit,name)
            XCTAssertEqual(preview["complete"] as? Bool,!slots.isEmpty,name)
            if slots.isEmpty { XCTAssertTrue(preview["start"] is NSNull); XCTAssertTrue(preview["end"] is NSNull) }
            for slot in slots {
                XCTAssertEqual(CalendarFreeBusy.instant(slot["end"]!)!.timeIntervalSince(CalendarFreeBusy.instant(slot["start"]!)!),Double(request.duration*60))
            }
            XCTAssertEqual(preview["send_invitations"] as? Bool,false)
            XCTAssertEqual(preview["requires_human_book"] as? Bool,true)
            XCTAssertEqual(result["side_effects"] as? Bool,false)
            XCTAssertEqual(result["booked"] as? Bool,false)
            XCTAssertEqual(result["teammate_availability"] as? String,"unknown")
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:result))
        }
    }

    func testInvalidInputsFailAndIncompleteAvailabilityCannotBecomeFreeTime() throws {
        for patch: [String:Any] in [["title":"  "],["title":"a\nb"],["title":String(repeating:"x",count:201)],
            ["time_zone":"Mars/Olympus"],["time_zone":"EST"],["duration_minutes":true],["duration_minutes":0],["duration_minutes":481],
            ["duration_minutes":1.5],["limit":21],["guests":[""]],["guests":Array(repeating:"A",count:21)],
            ["proposed_starts":[]],["proposed_starts":["2026-09-29T10:00:00"]]] {
            XCTAssertThrowsError(try CalendarProposal.Request(args.merging(patch) { _, new in new }))
        }
        let request = try CalendarProposal.Request(args)
        for availability: [String:Any] in [["complete":false,"scope":"own_calendar","busy":[]],
            ["complete":true,"scope":"guests","busy":[]],["complete":true,"scope":"own_calendar","busy":[["start":"bad","end":"bad"]]]] {
            XCTAssertThrowsError(try CalendarProposal.result(request,availability:availability,now:Date()))
        }
        let guests = try CalendarProposal.Request(args.merging(["guests":[" Jilles ","Harshil"]]) { _,new in new })
        XCTAssertEqual(guests.guests,["Jilles","Harshil"])
    }

    @MainActor func testHumanOnlyGrantIsIndependentAndNamedScopesCannotExpandIt() throws {
        let suite = "CalendarProposalTests-"+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertEqual(AgentConsent.status(defaults)["calendar_propose"],false)
        XCTAssertEqual(AgentConsent.requirements("calendar.propose"),["calendar_read","calendar_propose"])
        defaults.set(true,forKey:"agentCalendarReadEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("calendar.propose",args:args,defaults:defaults))
        defaults.set(true,forKey:"agentCalendarProposeEnabled") // Isolated synthetic defaults only.
        XCTAssertNoThrow(try AgentConsent.validate("calendar.propose",args:args,defaults:defaults))
        defaults.set(false,forKey:"agentCalendarReadEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("calendar.propose",args:args,defaults:defaults))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proposal-identities-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let registry = AgentIdentity(root:root)
        let (_, readToken) = try registry.issue(name:"Reader",scopes:["calendar_read"])
        let readPrincipal = try registry.authenticate(["credential":readToken])
        XCTAssertThrowsError(try registry.validate(readPrincipal,action:"calendar.propose"))
        let (agent, token) = try registry.issue(name:"Planner",scopes:["calendar_read","calendar_propose"])
        let principal = try registry.authenticate(["credential":token])
        XCTAssertNoThrow(try registry.validate(principal,action:"calendar.propose"))
        try registry.revoke(agent.id)
        XCTAssertThrowsError(try registry.validate(principal,action:"calendar.propose"))
        let actions = AgentActions.catalog["actions"] as! [[String:Any]]
        let settings = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String:Any]
        XCTAssertThrowsError(try AgentSchema.validate(["agentCalendarProposeEnabled":true],schema:settings))
        let proposal = actions.first { $0["name"] as? String == "calendar.propose" }!
        XCTAssertEqual(proposal["readOnly"] as? Bool,true)
        let schema = proposal["inputSchema"] as! [String:Any]
        for extra in ["book","confirm","busy","now","send_invitations"] {
            XCTAssertThrowsError(try AgentSchema.validate(args.merging([extra:true]) { _,new in new },schema:schema))
        }
    }
}
