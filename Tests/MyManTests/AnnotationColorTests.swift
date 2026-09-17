import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class AnnotationColorTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        return EditorModel(image: image, fileURL: URL(fileURLWithPath: "/tmp/color-fixture.png"),
                           preferences: UserDefaults(suiteName: "annotation-color-tests")!, persistPreferences: false)
    }

    @MainActor func testSelectingAndRecoloringKeepsOtherObjectsAndExportIndependent() throws {
        let model = model(), first = UUID(), second = UUID(), third = UUID()
        model.setAnnotationColor(.red, selected: nil)
        model.add(.filledBox(id: first, rect: CGRect(x: 20, y: 20, width: 80, height: 80)))
        model.add(.filledBox(id: second, rect: CGRect(x: 120, y: 20, width: 80, height: 80)))
        model.setAnnotationColor(.blue, selected: first)
        model.add(.filledBox(id: third, rect: CGRect(x: 220, y: 20, width: 80, height: 80)))
        model.setAnnotationColor(.green, selected: nil)
        XCTAssertEqual(model.color(for: model.annotations[0]), .blue)
        XCTAssertEqual(model.color(for: model.annotations[1]), .red)
        XCTAssertEqual(model.color(for: model.annotations[2]), .blue)
        model.move(first, by: CGVector(dx: 0, dy: 10))
        let image = model.renderFinal()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: AgentImages.png(image)))
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        for (x, expected) in [(60, NSColor.blue), (160, .red), (260, .blue)] {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(60 * scale))?.usingColorSpace(.sRGB))
            // AppKit color conversion can shift saturated components slightly;
            // verify the saved objects are blue/red/blue, never the new green default.
            if expected == .red {
                XCTAssertGreaterThan(pixel.redComponent, 0.9)
                XCTAssertLessThan(pixel.blueComponent, 0.25)
            } else {
                XCTAssertGreaterThan(pixel.blueComponent, 0.9)
                XCTAssertLessThan(pixel.redComponent, 0.25)
            }
            XCTAssertLessThan(pixel.greenComponent, 0.25)
        }
    }

    @MainActor func testHighlightsKeepTransparencyAndExplicitAgentColorsSurvive() {
        let model = model(), first = UUID(), second = UUID(), counter = UUID()
        model.add(.highlight(id: first, rect: CGRect(x: 20, y: 20, width: 80, height: 20)))
        model.add(.highlight(id: second, rect: CGRect(x: 120, y: 20, width: 80, height: 20)))
        model.setAnnotationColor(.blue, selected: first)
        XCTAssertEqual(model.color(for: model.annotations[0]), NSColor.blue.withAlphaComponent(EditorModel.highlightColor.alphaComponent))
        XCTAssertEqual(model.color(for: model.annotations[1]), EditorModel.highlightColor)
        model.annotationColors[counter] = .orange
        model.add(.counter(id: counter, center: CGPoint(x: 200, y: 200), number: 1))
        XCTAssertEqual(model.color(for: model.annotations[2]), .orange)
        model.setAnnotationColor(.green, selected: counter)
        XCTAssertEqual(model.color(for: model.annotations[2]), .green)
        model.undo()
        XCTAssertNil(model.annotationColors[counter])
    }

    @MainActor func testRenderMixedColorEditor() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let model = model()
        let box = UUID(), line = UUID(), counter = UUID()
        model.add(.box(id: box, rect: CGRect(x: 50, y: 40, width: 240, height: 140)))
        model.add(.line(id: line, from: CGPoint(x: 90, y: 140), to: CGPoint(x: 230, y: 70)))
        model.add(.counter(id: counter, center: CGPoint(x: 100, y: 250), number: 1))
        model.setAnnotationColor(.systemOrange, selected: box)
        model.setAnnotationColor(.systemBlue, selected: line)
        model.setAnnotationColor(.systemGreen, selected: counter)
        model.add(.counter(id: UUID(), center: CGPoint(x: 250, y: 250), number: 2))
        let host = NSHostingView(rootView: EditorView(model: model).frame(width: 1000, height: 650).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("independent-colors.png"))
    }
}
