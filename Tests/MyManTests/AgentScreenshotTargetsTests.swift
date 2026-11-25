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

final class AgentAltTextAndDocImageTests: XCTestCase {
    func testAltTextIsOneSentenceNamingTheAppTitleAndFirstWords() {
        let text = AgentAltText.make(app: "Safari", windowTitle: "Apple", text: "Total $42.00 for the order")
        XCTAssertEqual(text, "Screenshot of Safari, titled “Apple”, showing the text “Total $42.00 for the order”.")
    }
    func testAltTextFallsBackWithoutAnApp() {
        XCTAssertEqual(AgentAltText.make(app: nil, windowTitle: nil, text: ""), "Screenshot of the screen.")
        XCTAssertEqual(AgentAltText.make(app: "  ", windowTitle: "Same", text: ""), "Screenshot of the screen, titled “Same”.")
    }
    func testAltTextIsCapped() {
        let long = Array(repeating: "word", count: 500).joined(separator: " ")
        XCTAssertLessThanOrEqual(AgentAltText.make(app: "App", windowTitle: nil, text: long).count, AgentAltText.maximumLength)
    }
    func testDocImageStepsDownUntilItFitsTheByteCap() throws {
        // Pretend encoding shrinks with width; the first width that fits 4 MB wins.
        let fit = try XCTUnwrap(AgentDocImage.fit(width: 4000, height: 3000) { width in Data(count: Int(width) * 2_000) })
        XCTAssertLessThanOrEqual(fit.width, 2400)
        XCTAssertLessThanOrEqual(fit.data.count, AgentDocImage.maximumBytes)
    }
    func testDocImageNeverUpscalesAndRefusesWhenNothingFits() {
        let small = AgentDocImage.fit(width: 300, height: 200) { _ in Data(count: 100) }
        XCTAssertEqual(small?.width, 300)
        XCTAssertNil(AgentDocImage.fit(width: 4000, height: 3000) { _ in Data(count: AgentDocImage.maximumBytes + 1) })
    }
    func testSidecarCarriesMetadataAndNullsWhenUnknown() throws {
        let document = AgentOCRSidecar.document(text: "hi", regions: [], size: CGSize(width: 10, height: 10), scale: 2, capturedAt: "t", app: "Safari", windowTitle: "Apple", url: "https://example.com")
        let metadata = try XCTUnwrap(document["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["app"] as? String, "Safari"); XCTAssertEqual(metadata["url"] as? String, "https://example.com")
        let bare = AgentOCRSidecar.document(text: "", regions: [], size: CGSize(width: 1, height: 1), scale: 1, capturedAt: "t")
        XCTAssertTrue((try XCTUnwrap(bare["metadata"] as? [String: Any]))["app"] is NSNull)
    }
}
