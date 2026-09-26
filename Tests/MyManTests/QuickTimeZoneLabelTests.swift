import XCTest
@testable import MyMan

final class QuickTimeZoneLabelTests: XCTestCase {
    private let local = TimeZone(identifier: "America/New_York")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!

    func testExplicitUSCodesSurviveMatchingFixedOffsets() {
        for code in ["EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT"] {
            guard case .timeZone(let result) = QuickTimeZone.parse("9am \(code) to Iceland", now: now, local: local) else {
                return XCTFail(code)
            }
            XCTAssertEqual(result.sourceName, code)
            XCTAssertEqual(result.destinationName, "Iceland")
            XCTAssertEqual(result.displayZones.map(\.name), ["Iceland", code])
            XCTAssertTrue(result.markdown.hasPrefix(code + ":"))
            XCTAssertFalse(result.markdown.contains("GMT"))
        }
        guard case .timeZone(let result) = QuickTimeZone.parse("9am est to iceland", now: now, local: local) else {
            return XCTFail("Screenshot query must parse")
        }
        XCTAssertEqual(result.date, ISO8601DateFormatter().date(from: "2026-09-26T14:00:00Z"))
    }

    func testRegionalZonesUseSeasonalUSCodesAndInternationalCities() {
        for (day, expected) in [("2026-01-01T12:00:00Z", "EST"), ("2026-07-01T12:00:00Z", "EDT")] {
            let now = ISO8601DateFormatter().date(from: day)!
            guard case .timeZone(let result) = QuickTimeZone.parse("9am ET to London", now: now, local: local),
                  case .timeZone(let current) = QuickTimeZone.parse("time in Tokyo", now: now, local: local) else {
                return XCTFail("Regional conversion must parse")
            }
            XCTAssertEqual(result.sourceName, expected)
            XCTAssertEqual(result.destinationName, "London")
            XCTAssertEqual(current.sourceName, "Your time · " + expected)
            XCTAssertEqual(current.destinationName, "Tokyo")
        }
    }

    func testDestinationCodesAndExplicitOffsetsStayRecognizable() {
        guard case .timeZone(let result) = QuickTimeZone.parse("9am CST to EST", now: now, local: local),
              case .timeZone(let offset) = QuickTimeZone.parse("9am UTC+05:30 to UTC", now: now, local: local) else {
            return XCTFail("Fixed conversion must parse")
        }
        XCTAssertEqual(result.sourceName, "CST")
        XCTAssertEqual(result.destinationName, "EST")
        XCTAssertEqual(offset.sourceName, "UTC+05:30")
        XCTAssertEqual(offset.destinationName, "UTC")
        guard case .timeZone(let international) = QuickTimeZone.parse("9am Toronto to Shanghai", now: now, local: local) else {
            return XCTFail("International cities must parse")
        }
        XCTAssertEqual(international.sourceName, "Toronto")
        XCTAssertEqual(international.destinationName, "Shanghai")
    }
}
