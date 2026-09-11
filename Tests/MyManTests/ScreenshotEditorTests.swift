import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class ScreenshotEditorTests: XCTestCase {
    @MainActor private func fixtureImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor(white: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 110, height: 400).fill()
        let font = NSFont(name: "Gellix-Medium", size: 22) ?? NSFont.systemFont(ofSize: 22)
        ("Job Board" as NSString).draw(at: NSPoint(x: 140, y: 340), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        for x in [140, 300, 460] {
            NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: x, y: 45, width: 140, height: 260).fill()
            NSColor(white: 0.83, alpha: 1).setFill(); NSRect(x: x + 12, y: 250, width: 110, height: 4).fill()
            NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: x + 12, y: 200, width: 110, height: 4).fill()
        }
        image.unlockFocus()
        return image
    }

    @MainActor func testCustomBackdropPersistsAndIsExported() throws {
        let suite = "man.editor-test." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let image = fixtureImage(), url = URL(fileURLWithPath: "/tmp/screenshot-editor-fixture.png")
        let model = EditorModel(image: image, fileURL: url, preferences: preferences)
        model.customBackdropColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.7, alpha: 1)
        model.backdrop = .custom
        let restored = EditorModel(image: image, fileURL: url, preferences: preferences)
        XCTAssertEqual(restored.backdrop, .custom)
        XCTAssertEqual(restored.customBackdropColor.usingColorSpace(.sRGB)!.blueComponent, 0.7, accuracy: 0.01)
        let rendered = restored.renderFinal()
        XCTAssertGreaterThan(rendered.size.width, image.size.width)
        // Inspect the actual export representation, not NSImage's display-
        // converted CGImage or colorAt's calibrated-color interpretation.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: rendered.tiffRepresentation!))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let pixel = ctx.data!.assumingMemoryBound(to: UInt8.self).advanced(by: (2 * cg.width + 2) * 4)
        XCTAssertEqual(Double(pixel[0]) / 255, 0.2, accuracy: 0.01)
        XCTAssertEqual(Double(pixel[1]) / 255, 0.4, accuracy: 0.01)
        XCTAssertEqual(Double(pixel[2]) / 255, 0.7, accuracy: 0.01)
        let originalPixels = NSBitmapImageRep(data: image.tiffRepresentation!)!.pixelsWide
        XCTAssertEqual(cg.width, Int(ceil(rendered.size.width * Double(originalPixels) / image.size.width)))
        restored.backdrop = .none
        XCTAssertEqual(EditorModel(image: image, fileURL: url, preferences: preferences).backdrop, .none)
        XCTAssertEqual(EditorModel(image: image, fileURL: url, preferences: preferences).customBackdropColor.usingColorSpace(.sRGB)!.blueComponent, 0.7, accuracy: 0.01)
    }

    @MainActor func testMalformedSavedColorFallsBack() {
        let suite = "man.editor-test." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set([2.0, -0.1, 0.5], forKey: "screenshotCustomBackdropRGB")
        let model = EditorModel(image: fixtureImage(), fileURL: URL(fileURLWithPath: "/tmp/fixture.png"), preferences: preferences)
        XCTAssertEqual(model.customBackdropColor, BackdropStyle.ocean.colors![0])
    }

    func testRecentScreenshotUsesEnrichedTitleAndSource() {
        let shot = Screenshot(id: "example", path: "/tmp/example.png", ocrText: "Q, Search Tekmetric...\nJob Board\nRepair estimates", createdAt: Date())
        var item = CaptureItem(id: "shot-example", kind: "screenshot", sourceID: "example", rawTitle: "", generatedTitle: "Job Board", userTitle: "", body: shot.ocrText, summary: "", metadata: "", sourcePath: shot.path, capturedAt: shot.createdAt, modifiedAt: shot.createdAt, pinned: false, excluded: false, revision: 2)
        let context = ScreenshotContext(itemID: item.id, timezone: "America/New_York", app: "Google Chrome", url: "https://app.example.com/board")
        let value = ScreenshotRowDescription.make(shot: shot, item: item, context: context)
        XCTAssertEqual(value.title, "Job Board"); XCTAssertEqual(value.detail, "Google Chrome · app.example.com")
        item.userTitle = "My design reference"
        XCTAssertEqual(ScreenshotRowDescription.make(shot: shot, item: item, context: context).title, "My design reference")
        XCTAssertEqual(ScreenshotRowDescription.make(shot: shot, item: nil, context: nil).title, "Job Board")
    }

    @MainActor func testRenderScreenshotControls() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let suite = "man.editor-review." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let image = fixtureImage(), url = URL(fileURLWithPath: folder).appendingPathComponent("sample.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        let model = EditorModel(image: image, fileURL: url, preferences: preferences)
        model.customBackdropColor = NSColor(srgbRed: 0.25, green: 0.36, blue: 0.55, alpha: 1); model.backdrop = .custom
        let shot = Screenshot(id: "review-fixture", path: url.path, ocrText: "Q, Search Tekmetric...\nJob Board\nRepair estimates", createdAt: Date())
        let view = VStack(alignment: .leading, spacing: 20) {
            RecentScreenshotContent(shot: shot).frame(height: 64)
            Divider()
            CustomBackdropPicker(model: model)
            EditorView(model: model).frame(height: 500)
        }.padding(20).frame(width: 900).background(MM.Colors.background).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("screenshot-controls.png"))
    }
}
