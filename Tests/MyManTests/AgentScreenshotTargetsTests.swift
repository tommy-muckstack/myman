import XCTest
import AppKit
@testable import MyMan

final class AgentScreenshotTargetsTests: XCTestCase {
    private let windows = [
        AgentWindowMatch.Window(id: "101", app: "Safari", title: "Apple"),
        AgentWindowMatch.Window(id: "102", app: "Safari", title: "Safari guide"),
        AgentWindowMatch.Window(id: "201", app: "Notes", title: "Meeting notes"),
        AgentWindowMatch.Window(id: "301", app: "Mail", title: "Inbox")
    ]

    func testExactWindowIDWins() {
        XCTAssertEqual(AgentWindowMatch.resolve("201", in: windows), .one("201"))
    }

    func testAnExactAppNameBeatsATitleThatMerelyContainsIt() {
        // Chrome shows a page titled "Safari guide". Asking for Safari must not return it.
        let withChrome = windows + [AgentWindowMatch.Window(id: "401", app: "Chrome", title: "Safari guide")]
        XCTAssertEqual(AgentWindowMatch.resolve("Safari", in: withChrome), .many(windows.filter { $0.app == "Safari" }))
        XCTAssertEqual(AgentWindowMatch.resolve("mail", in: windows), .one("301"))
    }

    func testATitleFragmentFindsOneWindow() {
        XCTAssertEqual(AgentWindowMatch.resolve("meeting", in: windows), .one("201"))
    }

    func testAmbiguousNameReturnsEveryCandidate() {
        let outcome = AgentWindowMatch.resolve("Safari", in: windows)
        guard case .many(let candidates) = outcome else { return XCTFail("expected candidates, got \(outcome)") }
        XCTAssertEqual(candidates.map(\.id), ["101", "102"])
    }

    func testNoMatchAndEmptyQueryReturnNothing() {
        XCTAssertEqual(AgentWindowMatch.resolve("Calendar", in: windows), .none)
        XCTAssertEqual(AgentWindowMatch.resolve("   ", in: windows), .none)
    }

    func testOCRSidecarHasPixelGeometryAndNoRawImageData() throws {
        let regions = [AgentMarkup.Region(id: "ocr-1", text: "Total $42.00", rect: CGRect(x: 10, y: 20, width: 100, height: 14))]
        let document = AgentOCRSidecar.document(text: "Total $42.00", regions: regions, size: CGSize(width: 1280.4, height: 800), scale: 2, capturedAt: "2026-11-24T10:00:00.000Z")
        XCTAssertEqual(document["width"] as? Int, 1280); XCTAssertEqual(document["height"] as? Int, 800)
        XCTAssertEqual(document["coordinates"] as? String, "image-pixels-top-left")
        let lines = try XCTUnwrap(document["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["text"] as? String, "Total $42.00")
        XCTAssertEqual(lines.first?["box"] as? [Double], [10, 20, 100, 14])
        let data = try JSONSerialization.data(withJSONObject: document)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }
}
