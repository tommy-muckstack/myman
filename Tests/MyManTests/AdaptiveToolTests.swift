import XCTest
@testable import MyMan

final class AdaptiveToolTests: XCTestCase {
    private let local = TimeZone(identifier: "America/New_York")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testIcelandToLocalUsesSeasonalOffset() throws {
        for (day, hour) in [("2026-07-01T12:00:00Z", 4), ("2026-01-01T12:00:00Z", 3)] {
            guard case .timeZone(let result) = QuickTimeZone.parse("8am in iceland", now: date(day), local: local) else {
                return XCTFail("Expected time-zone conversion")
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = local
            XCTAssertEqual(calendar.component(.hour, from: result.date), hour)
            XCTAssertEqual(result.sourceName, "Iceland")
            XCTAssertEqual(result.destination, local)
        }
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("8am in iceland"), .create)
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("find 8am in iceland"), .search)
    }

    func testExplicitZonesHalfHoursAndDayRollover() throws {
        guard case .timeZone(let result) = QuickTimeZone.parse("8pm New York to India", now: date("2026-07-01T12:00:00Z"), local: local) else {
            return XCTFail("Expected explicit conversion")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = result.destination
        XCTAssertEqual(calendar.component(.hour, from: result.date), 5)
        XCTAssertEqual(calendar.component(.minute, from: result.date), 30)
        XCTAssertEqual(calendar.component(.day, from: result.date), 2)
        XCTAssertEqual(result.source, local)
        guard case .timeZone(let to) = QuickTimeZone.parse("14:30 to Iceland", now: date("2026-07-01T12:00:00Z"), local: local) else {
            return XCTFail("Expected local-to-destination conversion")
        }
        calendar.timeZone = to.destination
        XCTAssertEqual(calendar.component(.hour, from: to.date), 18)
        XCTAssertEqual(calendar.component(.minute, from: to.date), 30)
    }

    func testTimeZoneInvalidTimesAndDaylightSavingGaps() {
        for input in ["25:00 in Iceland", "13am in Iceland", "8:90 in Iceland", "8am in nowhere"] {
            guard case .incomplete = QuickTimeZone.parse(input, local: local) else { return XCTFail(input) }
        }
        for (input, day) in [("2:30am New York to Iceland", "2026-03-08T12:00:00Z"),
                             ("1:30am New York to Iceland", "2026-11-01T12:00:00Z")] {
            guard case .incomplete = QuickTimeZone.parse(input, now: date(day), local: local) else { return XCTFail(input) }
        }
        XCTAssertNil(QuickTimeZone.parse("5 miles in km"))
        XCTAssertNil(QuickTimeZone.parse("8 m in km"))
        XCTAssertNil(QuickTimeZone.parse("buy milk"))
    }

    func testCurrentTimeAndFixedOffsets() {
        let now = date("2026-07-01T12:00:00Z")
        guard case .timeZone(let current) = QuickTimeZone.parse("what time is it in Tokyo?", now: now, local: local),
              case .timeZone(let fixed) = QuickTimeZone.parse("8am UTC+05:30 to UTC", now: now, local: local) else {
            return XCTFail("Expected current time and fixed-offset conversions")
        }
        XCTAssertEqual(current.date, now)
        XCTAssertEqual(fixed.date, date("2026-07-01T02:30:00Z"))
        XCTAssertEqual(QuickTimeZone.zone("pst", local: local)?.secondsFromGMT(for: now), -28_800)
        XCTAssertEqual(QuickTimeZone.zone("pt", local: local)?.secondsFromGMT(for: now), -25_200)
    }

    func testPalettesHaveFourDistinctValidCompanionsIncludingNearWhite() {
        for input in ["#FFFFFD", "#FFFFFF", "#000000", "#808080", "#FF0000", "#00FF00", "#0000FF", "#FF6B35"] {
            let palette = QuickColorPalette.companions(for: input)
            XCTAssertEqual(palette.count, 4)
            XCTAssertEqual(Set(palette).count, 4)
            for hex in palette {
                XCTAssertNotNil(hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression))
                XCTAssertNotEqual(hex, input)
            }
        }
        XCTAssertEqual(QuickColorPalette.companions(for: "#FFFFFD"), QuickColorPalette.companions(for: "#FFFFFF"),
                       "Near-white noise should not produce a garish palette")
        let complement = QuickColorPalette.components(QuickColorPalette.companions(for: "#FF0000")[0])
        XCTAssertGreaterThan(complement.1, complement.0)
        XCTAssertEqual(complement.1, complement.2, accuracy: 0.01)
    }
}
