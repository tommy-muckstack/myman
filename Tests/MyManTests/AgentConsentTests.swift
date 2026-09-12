import XCTest
import AppKit
@testable import MyMan

final class AgentConsentTests: XCTestCase {
    @MainActor func testDefaultOffGroupsAndConfirmationCannotBeBypassed() throws {
        let name = "man-agent-consent-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for action in ["screenshot.capture", "screenshot.edit", "screenshot.capture_markup", "meeting.start", "dictation.start", "recording.start", "note.create", "item.delete"] {
            XCTAssertThrowsError(try AgentConsent.validate(action, args: [:], defaults: defaults)) { XCTAssertEqual(($0 as? AgentError)?.code, "AGENT_DISABLED") }
        }
        defaults.set(true, forKey: "agentCaptureEnabled")
        try AgentConsent.validate("screenshot.capture", args: [:], defaults: defaults)
        XCTAssertThrowsError(try AgentConsent.validate("screenshot.capture_markup", args: [:], defaults: defaults))
        defaults.set(true, forKey: "agentMarkupEnabled")
        try AgentConsent.validate("screenshot.capture_markup", args: [:], defaults: defaults)
        defaults.set(true, forKey: "agentLibraryEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("item.delete", args: [:], defaults: defaults)) { XCTAssertEqual(($0 as? AgentError)?.code, "CONFIRMATION_REQUIRED") }
        try AgentConsent.validate("item.delete", args: ["confirm": true], defaults: defaults)
        defaults.set(false, forKey: "agentActionsEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("screenshot.capture", args: [:], defaults: defaults))
        for action in ["app.doctor", "app.status", "settings.read", "recording.stop", "recording.cancel", "meeting.stop", "dictation.cancel"] { try AgentConsent.validate(action, args: [:], defaults: defaults) }
    }
    @MainActor func testSettingsSchemaCannotGrantAgentConsent() throws {
        let actions = AgentActions.catalog["actions"] as! [[String: Any]]
        let schema = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String: Any]
        for key in AgentConsent.keys.values { XCTAssertThrowsError(try AgentSchema.validate([key: true], schema: schema)) }
        XCTAssertThrowsError(try AgentSchema.validate(["agent_actions": true], schema: schema))
    }
    @MainActor func testPerAnnotationColorsRenderIndependently() throws {
        let image = NSImage(size: CGSize(width: 200, height: 100))
        image.lockFocus(); NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 200, height: 100).fill(); image.unlockFocus()
        image.size = AgentImages.size(image)
        let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: "/private/tmp/annotation-test.png"))
        let red = UUID(), blue = UUID()
        model.annotationColors[red] = .red; model.annotationColors[blue] = .blue
        model.add(.box(id: red, rect: CGRect(x: 10, y: 10, width: 60, height: 60)))
        model.add(.box(id: blue, rect: CGRect(x: 110, y: 10, width: 60, height: 60)))
        let png = try AgentImages.png(model.renderFinal())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let scale = Double(bitmap.pixelsWide) / image.size.width
        let redPixel = try XCTUnwrap(bitmap.colorAt(x: Int(10 * scale), y: Int(40 * scale))?.usingColorSpace(.sRGB))
        let bluePixel = try XCTUnwrap(bitmap.colorAt(x: Int(110 * scale), y: Int(40 * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(redPixel.redComponent, redPixel.blueComponent)
        XCTAssertGreaterThan(bluePixel.blueComponent, bluePixel.redComponent)
    }
    @MainActor func testPixelationSamplesRequestedTopLeftRegion() throws {
        let image = NSImage(size: CGSize(width: 120, height: 160))
        image.lockFocus()
        NSColor.blue.setFill(); CGRect(x: 0, y: 0, width: 120, height: 80).fill()
        NSColor.red.setFill(); CGRect(x: 0, y: 80, width: 120, height: 80).fill()
        image.unlockFocus()
        let patch = try XCTUnwrap(EditorModel.pixelated(image, in: CGRect(x: 10, y: 10, width: 40, height: 40)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: AgentImages.png(patch)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.blueComponent, 0.2)
    }

    func testRetinaImageMetadataMatchesEncodedPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cg = try XCTUnwrap(context.makeImage())
        let image = NSImage(cgImage: cg, size: CGSize(width: 200, height: 100))
        XCTAssertEqual(AgentImages.size(image), CGSize(width: 400, height: 200))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: AgentImages.png(image)))
        XCTAssertEqual(bitmap.pixelsWide, 400)
        XCTAssertEqual(bitmap.pixelsHigh, 200)
    }

}
