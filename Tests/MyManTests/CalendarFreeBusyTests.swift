import XCTest
import EventKit
@testable import MyMan

final class CalendarFreeBusyTests: XCTestCase {
    private let args = ["after": "2026-09-29T00:00:00-04:00", "before": "2026-09-30T00:00:00-04:00"]
    private func block(_ start: String, _ end: String) -> CalendarBusyBlock {
        .init(start: CalendarFreeBusy.instant(start)!, end: CalendarFreeBusy.instant(end)!)
    }

    func testRangeRequiresExplicitOffsetsAndValidDates() throws {
        let range = try CalendarFreeBusy.range(args)
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 86400)
        for text in ["2026-02-30T00:00:00Z", "2026-09-29", "2026-09-29T00:00:00", "2026-09-29T24:00:00Z", "2026-09-29T00:60:00Z", "2026-09-29T00:00:00+00:99"] {
            XCTAssertNil(CalendarFreeBusy.instant(text), text)
        }
        XCTAssertEqual(CalendarFreeBusy.instant("2026-09-29T10:00:00-04:00"), CalendarFreeBusy.instant("2026-09-29T14:00:00.000Z"))
        for bad in [["after":args["before"]!,"before":args["after"]!], ["after":args["after"]!,"before":args["after"]!], ["after":"2026-09-01T00:00:00Z","before":"2026-10-03T00:00:00Z"]] {
            XCTAssertThrowsError(try CalendarFreeBusy.range(bad))
        }
    }

    func testMergeClipsOverlapsAdjacentBlocksAndHalfOpenEndpoints() throws {
        let range = try CalendarFreeBusy.range(args)
        let blocks = [block("2026-09-29T13:00:00Z","2026-09-29T14:00:00Z"),
                      block("2026-09-29T12:00:00Z","2026-09-29T13:30:00Z"),
                      block("2026-09-29T14:00:00Z","2026-09-29T15:00:00Z"),
                      block("2026-09-29T15:00:00Z","2026-09-29T15:00:00Z"),
                      block("2026-09-29T01:00:00Z","2026-09-29T04:00:00Z"),
                      block("2026-09-30T04:00:00Z","2026-09-30T05:00:00Z"),
                      block("2026-09-29T03:00:00Z","2026-09-29T05:00:00Z")]
        XCTAssertEqual(try CalendarFreeBusy.merge(blocks, in: range), [block("2026-09-29T04:00:00Z","2026-09-29T05:00:00Z"),block("2026-09-29T12:00:00Z","2026-09-29T15:00:00Z")])
    }

    func testAllDayAndDSTAreAbsoluteIntervals() throws {
        let range = try CalendarFreeBusy.range(["after":"2026-11-01T00:00:00-04:00","before":"2026-11-02T00:00:00-05:00"])
        XCTAssertEqual(range.end.timeIntervalSince(range.start),25*3600)
        XCTAssertEqual(try CalendarFreeBusy.merge([range],in:range),[range])
    }

    func testCancelledDeclinedAndFreeEventsDoNotBlockButTentativeAndUnknownDo() {
        XCTAssertFalse(CalendarFreeBusyReader.isBusy(status:.canceled,availability:.busy,declined:false))
        XCTAssertFalse(CalendarFreeBusyReader.isBusy(status:.confirmed,availability:.free,declined:false))
        XCTAssertFalse(CalendarFreeBusyReader.isBusy(status:.confirmed,availability:.busy,declined:true))
        XCTAssertTrue(CalendarFreeBusyReader.isBusy(status:.tentative,availability:.tentative,declined:false))
        XCTAssertTrue(CalendarFreeBusyReader.isBusy(status:.none,availability:.notSupported,declined:false))
        XCTAssertTrue(CalendarFreeBusyReader.isBusy(status:.confirmed,availability:.unavailable,declined:false))
    }

    func testResultContainsOnlyBusyTimesAndNeverTruncates() throws {
        let range = try CalendarFreeBusy.range(args)
        let result = try CalendarFreeBusy.result([range],in:range)
        XCTAssertEqual(Set(result.keys),Set(["after","before","busy","source","scope","complete","side_effects","teammate_availability"]))
        let busy = try XCTUnwrap(result["busy"] as? [[String:String]])
        XCTAssertEqual(Set(busy[0].keys),Set(["start","end"]))
        XCTAssertEqual(result["teammate_availability"] as? String,"unknown")
        XCTAssertEqual(result["complete"] as? Bool,true)
        XCTAssertEqual(result["side_effects"] as? Bool,false)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:result))
        XCTAssertThrowsError(try CalendarFreeBusy.result(Array(repeating:range,count:10_001),in:range)) {
            XCTAssertEqual(($0 as? AgentError)?.code,"CALENDAR_LIMIT_EXCEEDED")
        }
        XCTAssertEqual((try CalendarFreeBusy.result([],in:range))["busy"] as? [[String:String]],[])
    }

    @MainActor func testIndependentDefaultOffGrantDoctorAndSettingsCannotEnableIt() throws {
        let suite = "FreeBusyTests-"+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertEqual(AgentConsent.status(defaults)["calendar_read"],false)
        defaults.set(true,forKey:"agentLibraryEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("calendar.freebusy",args:args,defaults:defaults))
        defaults.set(true,forKey:"agentCalendarReadEnabled") // Synthetic suite only.
        XCTAssertNoThrow(try AgentConsent.validate("calendar.freebusy",args:args,defaults:defaults))
        defaults.set(false,forKey:"agentActionsEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("calendar.freebusy",args:args,defaults:defaults))
        let actions = AgentActions.catalog["actions"] as! [[String:Any]]
        let schema = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String:Any]
        XCTAssertThrowsError(try AgentSchema.validate(["agentCalendarReadEnabled":true],schema:schema))
    }
}
