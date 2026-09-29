import XCTest
@testable import MyMan

final class SchedulingIntentTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-09-29T16:00:00Z")!
    private let zone = TimeZone(identifier: "America/New_York")!
    private func parse(_ text: String) -> SchedulingIntent {
        SchedulingIntentParser.parse(text, reference: reference, timeZone: zone)
    }

    func testDemoPeopleRemainLiteralAndMissingFieldsAreNotInvented() {
        let intent = parse("meeting with jilles and harshil")
        XCTAssertEqual(intent.title, "meeting")
        XCTAssertEqual(intent.people, ["jilles", "harshil"])
        XCTAssertNil(intent.day); XCTAssertNil(intent.time); XCTAssertNil(intent.durationMinutes)
        XCTAssertEqual(intent.missing, ["day", "time", "duration_minutes"])
        XCTAssertTrue(intent.issues.isEmpty)
    }

    func testFullExampleAndJSONContract() throws {
        let intent = parse("Coffee with Developer Friday at 10am for 30 min")
        XCTAssertEqual(intent.title, "Coffee")
        XCTAssertEqual(intent.people, ["Developer"])
        XCTAssertEqual(intent.day, "2026-10-02")
        XCTAssertEqual(intent.time, "10:00")
        XCTAssertEqual(intent.durationMinutes, 30)
        XCTAssertEqual(intent.missing, [])
        XCTAssertEqual(intent.issues, [])
        let bytes = try JSONSerialization.data(withJSONObject: intent.json)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["side_effects"] as? Bool, false)
        XCTAssertEqual(json["requires_human_booking"] as? Bool, true)
        XCTAssertEqual(json["time_zone"] as? String, "America/New_York")
        XCTAssertEqual(json["needs_clarification"] as? Bool, false)
        XCTAssertTrue(parse("meeting").json["day"] is NSNull)
    }

    func testWhitespaceUnicodeAndDeduplication() {
        let intent = parse("  Please schedule a Coffee with José Núñez, Zoë & José Núñez\n tomorrow at 2:30PM for 0.75 hours! ")
        XCTAssertEqual(intent.title, "Coffee")
        XCTAssertEqual(intent.people, ["José Núñez", "Zoë"])
        XCTAssertEqual(intent.day, "2026-09-30")
        XCTAssertEqual(intent.time, "14:30")
        XCTAssertEqual(intent.durationMinutes, 45)
        XCTAssertEqual(intent.issues, [])
    }

    func testVagueEmptyAndBoundedInput() {
        for phrase in ["", " \n ", "sometime next week"] {
            let intent = parse(phrase)
            XCTAssertNil(intent.title); XCTAssertNil(intent.day); XCTAssertNil(intent.time)
            XCTAssertNil(intent.durationMinutes); XCTAssertTrue(intent.people.isEmpty)
            XCTAssertFalse(intent.missing.isEmpty)
        }
        XCTAssertEqual(parse("sometime next week").issues, ["vague_or_recurring_schedule"])
        XCTAssertTrue(parse("meeting with someone tomorrow afternoon").people.isEmpty)
        XCTAssertEqual(parse(String(repeating: "x", count: 2001)).issues, ["input_too_long"])
    }

    func testWeekdayPolicyAndYearBoundary() {
        XCTAssertEqual(parse("review Tuesday").day, "2026-09-29")
        XCTAssertEqual(parse("review next Tuesday").day, "2026-10-06")
        XCTAssertEqual(parse("review next Friday").day, "2026-10-02")
        let yearEnd = ISO8601DateFormatter().date(from: "2026-12-31T18:00:00Z")!
        XCTAssertEqual(SchedulingIntentParser.parse("review tomorrow", reference: yearEnd, timeZone: zone).day, "2027-01-01")
    }

    func testRelativeDaysUseSuppliedZoneAndCalendarAcrossDST() {
        let midnight = ISO8601DateFormatter().date(from: "2026-09-30T01:00:00Z")!
        XCTAssertEqual(SchedulingIntentParser.parse("review today", reference: midnight, timeZone: zone).day, "2026-09-29")
        XCTAssertEqual(SchedulingIntentParser.parse("review today", reference: midnight, timeZone: TimeZone(secondsFromGMT: 0)!).day, "2026-09-30")
        for (instant, expected) in [("2026-03-08T05:30:00Z", "2026-03-09"), ("2026-11-01T04:30:00Z", "2026-11-02")] {
            let now = ISO8601DateFormatter().date(from: instant)!
            XCTAssertEqual(SchedulingIntentParser.parse("review tomorrow", reference: now, timeZone: zone).day, expected)
        }
    }

    func testExplicitDatesTimesAndInvalidValues() {
        XCTAssertEqual(parse("review on 2028-02-29 at noon for 1 hour").day, "2028-02-29")
        XCTAssertEqual(parse("review at noon").time, "12:00")
        XCTAssertEqual(parse("review at midnight").time, "00:00")
        XCTAssertEqual(parse("review at 12am").time, "00:00")
        XCTAssertEqual(parse("review at 12pm").time, "12:00")
        XCTAssertEqual(parse("review at 14:45").time, "14:45")
        for text in ["review on 2026-02-29", "review on 2026-13-01"] {
            XCTAssertNil(parse(text).day); XCTAssertTrue(parse(text).issues.contains("invalid_day"))
        }
        for text in ["review at 25:00", "review at 9:70am", "review at 13pm", "review at 0am"] {
            XCTAssertNil(parse(text).time); XCTAssertTrue(parse(text).issues.contains("invalid_time"))
        }
        for duration in ["0 min", "-30 min", "481 min", "0.5 min", "99999999999999999999999 hours"] {
            XCTAssertNil(parse("review for " + duration).durationMinutes)
            XCTAssertTrue(parse("review for " + duration).issues.contains("invalid_duration"))
        }
    }

    func testAmbiguityAndUnsupportedSyntaxCannotLookComplete() {
        XCTAssertNil(parse("meeting at 10").time)
        XCTAssertTrue(parse("meeting at 10").issues.contains("ambiguous_time"))
        XCTAssertNil(parse("meeting Friday or Saturday").day)
        XCTAssertNil(parse("meeting at 10am or 2pm").time)
        XCTAssertNil(parse("meeting for 30 min or for 45 min").durationMinutes)
        XCTAssertNil(parse("meeting at 10am PST").time)
        for text in ["meeting with Alex next week", "meeting with Alex on 10/2", "meeting with Alex every Friday", "meeting with Alex at ten", "meeting with Alex for half an hour"] {
            XCTAssertFalse(parse(text).issues.isEmpty, text)
            XCTAssertEqual(parse(text).json["needs_clarification"] as? Bool, true, text)
        }
    }

    func testModelExtractionIsGroundedAndCannotChangeTemporalFields() async {
        let input = "Alex and Sam coffee Friday at 10am for 30 min"
        let result = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone,
            extractor: { _ in .init(title: "coffee", people: ["Alex", "Sam"]) })
        XCTAssertEqual(result.engine, "foundation_models")
        XCTAssertEqual(result.intent.people, ["Alex", "Sam"])
        XCTAssertEqual(result.intent.title, "coffee")
        XCTAssertEqual(result.intent.day, "2026-10-02")
        XCTAssertEqual(result.intent.time, "10:00")
        XCTAssertEqual(result.intent.durationMinutes, 30)
        for people in [["Invented"], ["Friday"], ["Al"], ["Alex", "Alex"]] {
            let rejected = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone,
                extractor: { _ in .init(title: "coffee", people: people) })
            XCTAssertEqual(rejected.engine, "deterministic")
            XCTAssertEqual(rejected.intent, parse(input))
        }
    }

    func testModelFailureUnavailabilityDisabledAndCancellationUseFallback() async {
        struct Failure: Error {}
        let input = "Alex coffee tomorrow"
        let failed = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone,
            extractor: { _ in throw Failure() })
        let unavailable = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone,
            extractor: { _ in nil })
        let disabled = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone, useModel: false,
            extractor: { _ in XCTFail("Disabled model must not run"); return nil })
        let cancelled = await SchedulingIntentService.parse(input, reference: reference, timeZone: zone,
            extractor: { _ in throw CancellationError() })
        for result in [failed, unavailable, disabled, cancelled] {
            XCTAssertEqual(result.engine, "deterministic"); XCTAssertEqual(result.intent, parse(input))
        }
    }

    @MainActor func testActionValidationAndDefaultOffGrantCannotBeEnabledBySettingsAction() async throws {
        let suite = "SchedulingIntentTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentConsent.status(defaults)["scheduling_parse"], false)
        defaults.set(true, forKey: "agentLibraryEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("scheduling.parse", args: [:], defaults: defaults))
        defaults.set(true, forKey: "agentSchedulingParseEnabled") // Isolated fixture only.
        XCTAssertNoThrow(try AgentConsent.validate("scheduling.parse", args: [:], defaults: defaults))
        let actions = AgentActions.catalog["actions"] as! [[String: Any]]
        let settings = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String: Any]
        XCTAssertThrowsError(try AgentSchema.validate(["agentSchedulingParseEnabled": true], schema: settings))
        let json = try await AgentScheduling.parse(["input": "Coffee with Developer Friday at 10am for 30 min",
                                                   "reference": "2026-09-29T12:00:00-04:00", "time_zone": "America/New_York", "use_model": false])
        XCTAssertEqual(json["day"] as? String, "2026-10-02")
        XCTAssertEqual(json["engine"] as? String, "deterministic")
        for args: [String: Any] in [["input": "review", "reference": "tomorrow"], ["input": "review", "time_zone": "Mars/Olympus"]] {
            do { _ = try await AgentScheduling.parse(args); XCTFail("Must reject invalid context") }
            catch { XCTAssertEqual((error as? AgentError)?.code, "INVALID_ARGUMENTS") }
        }
    }
}
