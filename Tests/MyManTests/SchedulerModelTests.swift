import XCTest
@testable import MyMan

final class SchedulerModelTests: XCTestCase {
    func testSchedulingRoutingPreservesCalendarAndSearch() {
        for text in ["schedule with mary", "meeting with jilles and harshil", "Coffee with Developer Friday at 10am for 30 min", "book a meeting tomorrow"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(text), .schedule, text)
        }
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("my schedule"), .calendar)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("schedule tomorrow"), .calendar)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find meeting with Mary"), .search)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("record meeting"), .action("meeting"))
    }
    func testCalendarCreationPhrasesOpenSchedulerInsteadOfCreatingNotes() {
        for text in ["create call invite", "create a call invite", "create a new call invite", "Create a meeting invitation with Mary tomorrow at 10am",
                     "please make a calendar invite", "new meeting", "create an appointment Friday",
                     "make a phone call with Mary", "create a video call", "new calendar event", "create an event tomorrow"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(text), .schedule, text)
        }
        for text in ["create meeting notes", "create call notes", "create a call script", "new meeting agenda",
                     "create a meeting invite template", "create call invite checklist", "create a checklist",
                     "create calligraphy", "make a note about a call invite"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(text), .create, text)
        }
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find call invite"), .search)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("show me meeting invitations"), .search)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("record a meeting"), .action("meeting"))
    }
    func testCreationWordingIsRemovedBeforeSchedulingParse() {
        let now = CalendarFreeBusy.instant("2026-09-30T08:00:00Z")!
        let intent = SchedulingIntentParser.parse(SchedulerModel.schedulingText("Please create a call invite with Mary tomorrow at 10am for 30 min"),
                                                 reference: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(intent.title, "call invite"); XCTAssertEqual(intent.people, ["Mary"])
        XCTAssertEqual(intent.day, "2026-10-01"); XCTAssertEqual(intent.time, "10:00"); XCTAssertEqual(intent.durationMinutes, 30)
        let bare = SchedulingIntentParser.parse(SchedulerModel.schedulingText("create call invite"), reference: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(bare.title, "call invite"); XCTAssertTrue(bare.people.isEmpty)
        XCTAssertNil(bare.day); XCTAssertNil(bare.time)
        XCTAssertEqual(SchedulerModel.schedulingText("create meeting notes"), "create meeting notes")
    }
    @MainActor func testPreviewSelectionBoundariesAndInvalidation() async throws {
        let now = CalendarFreeBusy.instant("2026-09-30T08:00:00Z")!
        let model = SchedulerModel(zone:TimeZone(identifier:"UTC")!, now:{ now }, authorize:{ _ in }, read:{ args in
            let range = try CalendarFreeBusy.range(args)
            return try CalendarFreeBusy.result([.init(start:now.addingTimeInterval(3600),end:now.addingTimeInterval(7200))],in:range)
        },resolve:{ _ in [] })
        await model.load("Coffee with Mary today at 10am for 30 min")
        XCTAssertEqual(model.people,["Mary"]); XCTAssertEqual(model.title,"Coffee")
        XCTAssertEqual(model.selected,now.addingTimeInterval(7200));XCTAssertTrue(model.canReview)
        model.select(now.addingTimeInterval(5400));XCTAssertNil(model.selected)
        model.select(now.addingTimeInterval(7200));XCTAssertTrue(model.canReview)
        model.invalidate();XCTAssertFalse(model.hasAvailability);XCTAssertNil(model.selected)
    }
    @MainActor func testGrantsPreventCalendarAndPeopleReads() async {
        var reads = 0
        let model = SchedulerModel(authorize:{ _ in throw AgentError("AGENT_DISABLED","Denied") },read:{ _ in reads += 1;return [:] },resolve:{ _ in XCTFail("No people read");return [] })
        await model.load("schedule with mary")
        XCTAssertEqual(reads,0);XCTAssertTrue(model.needsGrants);XCTAssertFalse(model.canReview)
    }
    @MainActor func testInvalidationDiscardsInFlightAvailability() async {
        var continuation: CheckedContinuation<[String:Any],Error>?
        let model = SchedulerModel(authorize:{ _ in },read:{ _ in try await withCheckedThrowingContinuation { continuation = $0 } },resolve:{ _ in [] })
        let task = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        model.invalidate();continuation?.resume(returning:["complete":true,"scope":"own_calendar","busy":[]])
        await task.value
        XCTAssertFalse(model.hasAvailability);XCTAssertNil(model.selected);XCTAssertTrue(model.slots.isEmpty)
    }
    @MainActor func testRevocationDuringReadDiscardsAvailability() async {
        var allowed = true
        let model = SchedulerModel(authorize:{ _ in if !allowed { throw AgentError("AGENT_DISABLED","Denied") } },read:{ _ in
            allowed = false;return ["complete":true,"scope":"own_calendar","busy":[]]
        },resolve:{ _ in [] })
        await model.refresh();XCTAssertFalse(model.canReview);XCTAssertTrue(model.needsGrants)
    }
}
