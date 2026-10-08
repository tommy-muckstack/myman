import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class QuickTimeZoneLabelTests: XCTestCase {
    private let local = TimeZone(identifier: "America/New_York")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!

    func testSingleDestinationAlwaysStartsAtTheCurrentLocation() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        for input in ["9am in Iceland", "9 am in Iceland", "9am Iceland", "9am to Iceland", "09:00 in Iceland"] {
            guard case .timeZone(let result) = QuickTimeZone.parse(input, now: now, local: local) else { return XCTFail(input) }
            XCTAssertEqual(result.date, ISO8601DateFormatter().date(from: "2026-10-08T13:00:00Z"))
            XCTAssertEqual(result.source, local)
            XCTAssertEqual(result.destination.identifier, "Atlantic/Reykjavik")
            XCTAssertEqual(result.displayZones.map(\.name), ["Your time · EDT", "Iceland"])
            XCTAssertTrue(result.markdown.hasPrefix("Your time · EDT:"))
        }
        let visiting = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        guard case .timeZone(let travel) = QuickTimeZone.parse("9am in Iceland", now: now, local: visiting) else { return XCTFail() }
        XCTAssertEqual(travel.source, visiting)
        XCTAssertEqual(travel.date, ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z"))
    }

    func testHoustonAndDCAliasesUseRegionalRulesAndRecognizableNames() throws {
        for (day, suffix) in [("2026-10-08T12:00:00Z", "DT"), ("2026-01-08T12:00:00Z", "ST")] {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: day))
            for (place, expectedZone, hour, name) in [
                ("Houston", "America/Chicago", 16, "Houston · C" + suffix),
                ("Houston, TX", "America/Chicago", 16, "Houston · C" + suffix),
                ("Houston Texas", "America/Chicago", 16, "Houston · C" + suffix),
                ("DC", "America/New_York", 17, "Washington, DC · E" + suffix),
                ("D.C.", "America/New_York", 17, "Washington, DC · E" + suffix),
                ("Washington, D.C.", "America/New_York", 17, "Washington, DC · E" + suffix),
                ("Washington DC", "America/New_York", 17, "Washington, DC · E" + suffix),
                ("District of Columbia", "America/New_York", 17, "Washington, DC · E" + suffix)
            ] {
                guard case .timeZone(let result) = QuickTimeZone.parse("5pm in \(place)", now: now, local: local) else { return XCTFail(place) }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = result.destination
                XCTAssertEqual(result.source, local)
                XCTAssertEqual(result.destination.identifier, expectedZone)
                XCTAssertEqual(calendar.component(.hour, from: result.date), hour)
                XCTAssertEqual(result.destinationName, name)
                XCTAssertEqual(result.displayZones.first?.zone, local)
            }
        }
    }

    func testExplicitReverseAndLocalDaylightSavingValidation() {
        guard case .timeZone(let reverse) = QuickTimeZone.parse("9am Iceland to here", now: now, local: local) else { return XCTFail() }
        XCTAssertEqual(reverse.source.identifier, "Atlantic/Reykjavik")
        XCTAssertEqual(reverse.destination, local)
        XCTAssertEqual(reverse.displayZones.first?.zone, reverse.source)
        for (query, day) in [("2:30am in Houston", "2026-03-08T12:00:00Z"), ("1:30am in DC", "2026-11-01T12:00:00Z")] {
            guard case .incomplete = QuickTimeZone.parse(query, now: ISO8601DateFormatter().date(from: day)!, local: local) else { return XCTFail(query) }
        }
        guard case .timeZone(let midnight) = QuickTimeZone.parse("11pm in Iceland", now: now, local: local) else { return XCTFail() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = midnight.destination
        XCTAssertEqual(calendar.component(.day, from: midnight.date), 27)
        XCTAssertEqual(calendar.component(.hour, from: midnight.date), 3)
    }

    @MainActor func testLocalFirstCardFixtures() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_TIMEZONE_SCREENSHOTS"] else { throw XCTSkip("Opt-in native layout review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for place in ["Iceland", "Houston", "DC"] {
            let query = place == "Iceland" ? "9 am in Iceland" : "5pm in \(place)"
            let model = QuickToolsModel()
            model.tool = try XCTUnwrap(QuickTimeZone.parse(query, now: ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!, local: local))
            let host = NSHostingView(rootView: QuickToolCard(model: model).frame(width: 620)
                .background(MM.Colors.background).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(place + ".png"))
            window.contentView = nil
            window.close()
        }
    }

    func testExplicitUSCodesSurviveMatchingFixedOffsets() {
        for code in ["EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT"] {
            guard case .timeZone(let result) = QuickTimeZone.parse("9am \(code) to Iceland", now: now, local: local) else {
                return XCTFail(code)
            }
            XCTAssertEqual(result.sourceName, code)
            XCTAssertEqual(result.destinationName, "Iceland")
            XCTAssertEqual(result.displayZones.map(\.name), [code, "Iceland"])
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
