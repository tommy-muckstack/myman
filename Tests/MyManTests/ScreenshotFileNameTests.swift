import XCTest
@testable import MyMan

final class ScreenshotFileNameTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var date: Date { Date(timeIntervalSince1970: 1_764_076_800) } // 2025-11-25 13:20:00 UTC

    func testDefaultTemplateRendersDateAndTime() {
        XCTAssertEqual(ScreenshotFileName.render(ScreenshotFileName.defaultTemplate, date: date, id: "abcdef123456", timeZone: utc), "My Man 2025-11-25 at 13.20.00")
    }

    func testIdTokenUsesTheFirstEightCharacters() {
        XCTAssertEqual(ScreenshotFileName.render("shot-{id}", date: date, id: "abcdef123456", timeZone: utc), "shot-abcdef12")
    }

    func testSlashesAndColonsAreRemoved() {
        let name = ScreenshotFileName.render("a/b:c {time}", date: date, id: "x", timeZone: utc)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(":"))
    }

    func testEmptyTemplateFallsBackToDefault() {
        let suite = "man-shotname-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("   ", forKey: ScreenshotFileName.key)
        XCTAssertEqual(ScreenshotFileName.template(defaults), ScreenshotFileName.defaultTemplate)
        defaults.removePersistentDomain(forName: suite)
    }

    func testNameClashGetsANumberedSuffix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shotnames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ScreenshotFileName.url(in: folder, template: "shot", date: date, id: "x")
        try Data().write(to: first)
        let second = ScreenshotFileName.url(in: folder, template: "shot", date: date, id: "x")
        XCTAssertEqual(second.lastPathComponent, "shot 2.png")
    }
}
