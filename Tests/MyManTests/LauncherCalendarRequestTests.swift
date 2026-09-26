import XCTest
@testable import MyMan

final class LauncherCalendarRequestTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testNaturalSchedulePhrasesRouteWithoutExpandingTheMenu() {
        let groups: [(LauncherCalendarRequest, [String])] = [
            (.today, ["meetings today", "my meetings today", "today's meetings", "show me meetings today", "What's on today?", "my agenda"]),
            (.tomorrow, ["meetings tomorrow", "tomorrow’s schedule", "what do I have tomorrow?", "show me my calendar tomorrow"]),
            (.weekday(6), ["meetings on Friday", "agenda for fri", "what's on my calendar on Friday?"]),
            (.week, ["this week's meetings", "meetings this week", "schedule for this week"]),
            (.next, ["what's next?", "next meeting", "when is my next meeting?", "what is my next meeting"]),
            (.upcoming, ["upcoming meetings", "upcoming events"])
        ]
        for (expected, inputs) in groups {
            for input in inputs {
                XCTAssertEqual(LauncherCalendarRequest.parse(input), expected, input)
                XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .calendar, input)
            }
        }
        for input in ["my open tasks", "to-do list", "what do i need to do", "show me my tasks"] {
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .tasks, input)
        }
    }

    func testSavedMeetingSearchesAndCreationKeepTheirMeaning() {
        for input in ["find meetings today", "show me meeting notes", "find tomorrow's agenda", "search for calendar notes"] {
            XCTAssertNil(LauncherCalendarRequest.parse(input), input)
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .search, input)
        }
        for input in ["meeting with Sam", "meetings today notes", "calendar redesign"] {
            XCTAssertNil(LauncherCalendarRequest.parse(input), input)
            XCTAssertEqual(AdaptiveLauncherIntent.resolve(input), .choose, input)
        }
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("create a meeting agenda"), .create)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("record meeting"), .action("meeting"))
        var routing = AdaptiveLauncherRouting()
        routing.selection = .search
        routing.update("meetings today")
        XCTAssertEqual(routing.selection, .search)
    }

    func testDatesRespectWeekBoundariesAndDaylightSaving() {
        let now = date("2026-09-26T16:00:00Z")
        XCTAssertEqual(LauncherCalendarRequest.tomorrow.selectedDate(now: now, calendar: calendar), date("2026-09-27T04:00:00Z"))
        XCTAssertEqual(LauncherCalendarRequest.weekday(2).selectedDate(now: now, calendar: calendar), date("2026-09-28T04:00:00Z"))
        XCTAssertEqual(LauncherCalendarRequest.weekday(7).selectedDate(now: now, calendar: calendar), date("2026-09-26T04:00:00Z"))
        XCTAssertEqual(LauncherCalendarRequest.week.startDate(now: now, calendar: calendar), date("2026-09-21T04:00:00Z"))
        let spring = date("2026-03-08T16:00:00Z")
        let start = LauncherCalendarRequest.today.startDate(now: spring, calendar: calendar)
        let tomorrow = LauncherCalendarRequest.tomorrow.selectedDate(now: spring, calendar: calendar)
        XCTAssertEqual(tomorrow.timeIntervalSince(start), 23 * 3600)
    }

    @MainActor func testNextMeetingDaySelectionAndUpcomingFiltering() {
        let now = date("2026-09-26T16:00:00Z")
        func event(_ id: String, hour: Double, allDay: Bool = false) -> CalendarPanelView.EventLite {
            .init(id: id, start: now.addingTimeInterval(hour * 3600), end: now.addingTimeInterval((hour + 1) * 3600),
                  title: id, notes: "", attendeeNames: [], isAllDay: allDay)
        }
        let days: [CalendarPanelView.DayEvents] = [
            .init(id: "today", date: calendar.startOfDay(for: now),
                  events: [event("past", hour: -2), event("all-day", hour: 0, allDay: true), event("next", hour: 1)]),
            .init(id: "tomorrow", date: LauncherCalendarRequest.tomorrow.selectedDate(now: now, calendar: calendar),
                  events: [event("tomorrow-event", hour: 24)])
        ]
        var agenda = InlineCalendarAgenda(days: days, request: .next, now: now, calendar: calendar)
        XCTAssertEqual(agenda.sections.flatMap(\.events).map(\.id), ["next"])
        agenda.selectedDay = 1
        XCTAssertEqual(agenda.sections.flatMap(\.events).map(\.id), ["tomorrow-event"])
        agenda.selectedDay = nil
        agenda.request = .tomorrow
        XCTAssertEqual(agenda.activeDay, 1)
        agenda.request = .upcoming
        XCTAssertEqual(agenda.sections.flatMap(\.events).map(\.id), ["all-day", "next", "tomorrow-event"])
        agenda.request = .week
        XCTAssertEqual(agenda.sections.flatMap(\.events).count, 4)
        agenda.request = .next
        agenda.now = now.addingTimeInterval(26 * 3600)
        XCTAssertTrue(agenda.sections.isEmpty)
    }
}
