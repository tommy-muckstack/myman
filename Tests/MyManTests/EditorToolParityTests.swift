import XCTest
import AppKit
@testable import MyMan

/// CleanShot-parity tools: filled rectangle, ellipse, line, counter, pen,
/// stroke width — geometry, editing, and export all agree.
final class EditorToolParityTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        return EditorModel(image: image, fileURL: URL(fileURLWithPath: "/tmp/parity-fixture.png"),
                           preferences: UserDefaults(suiteName: "parity-tests")!, persistPreferences: false)
    }

    @MainActor func testNewShapesHitMoveResizeAndNumber() {
        let m = model()
        let ellipse = UUID(), line = UUID(), pen = UUID()
        m.add(.ellipse(id: ellipse, rect: CGRect(x: 10, y: 10, width: 100, height: 60)))
        m.add(.line(id: line, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 260)))
        m.add(.pen(id: pen, points: [CGPoint(x: 50, y: 250), CGPoint(x: 80, y: 280), CGPoint(x: 120, y: 260)]))
        XCTAssertEqual(m.hitTest(CGPoint(x: 60, y: 40), tolerance: 4), ellipse)
        XCTAssertEqual(m.hitTest(CGPoint(x: 250, y: 230), tolerance: 4), line)
        XCTAssertEqual(m.hitTest(CGPoint(x: 100, y: 270), tolerance: 4), pen)
        XCTAssertNil(m.hitTest(CGPoint(x: 350, y: 20), tolerance: 4))
        XCTAssertEqual(m.handles(for: m.annotations[0]).count, 8)
        XCTAssertEqual(m.handles(for: m.annotations[1]).map(\.handle), [.arrowStart, .arrowEnd])
        XCTAssertTrue(m.handles(for: m.annotations[2]).isEmpty)
        m.resize(ellipse, handle: .right, to: CGPoint(x: 150, y: 0))
        XCTAssertEqual(m.annotations[0].rect, CGRect(x: 10, y: 10, width: 140, height: 60))
        m.resize(line, handle: .arrowStart, to: CGPoint(x: 180, y: 180))
        guard case .line(_, let from, _) = m.annotations[1] else { return XCTFail() }
        XCTAssertEqual(from, CGPoint(x: 180, y: 180))
        m.move(pen, by: CGVector(dx: 10, dy: -10))
        XCTAssertEqual(m.bounds(of: m.annotations[2]).origin, CGPoint(x: 60, y: 240))
        XCTAssertEqual(m.nextCounterNumber, 1)
        m.add(.counter(id: UUID(), center: CGPoint(x: 30, y: 30), number: m.nextCounterNumber))
        m.add(.counter(id: UUID(), center: CGPoint(x: 90, y: 30), number: m.nextCounterNumber))
        XCTAssertEqual(m.nextCounterNumber, 3)
        XCTAssertNotNil(m.hitTest(CGPoint(x: 92, y: 31), tolerance: 2))
    }

    @MainActor func testStrokeWidthIsRememberedPerAnnotationAndExported() throws {
        let m = model()
        m.strokeWidth = 8
        let box = UUID()
        m.add(.filledBox(id: box, rect: CGRect(x: 100, y: 100, width: 100, height: 50)))
        m.strokeWidth = 2
        let line = UUID()
        m.add(.line(id: line, from: CGPoint(x: 0, y: 290), to: CGPoint(x: 399, y: 290)))
        XCTAssertEqual(m.strokeWidth(for: box), 8)
        XCTAssertEqual(m.strokeWidth(for: line), 2)
        let rendered = m.renderFinal()
        let cg = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(cg.width) / rendered.size.width
        // Filled rectangle centre carries the annotation colour; a corner of
        // the image is still white.
        let inside = try XCTUnwrap(bitmap.colorAt(x: Int(150 * scale), y: Int(125 * scale)))
        let corner = try XCTUnwrap(bitmap.colorAt(x: Int(5 * scale), y: Int(5 * scale)))
        XCTAssertGreaterThan(inside.redComponent, 0.8); XCTAssertLessThan(inside.greenComponent, 0.5)
        XCTAssertGreaterThan(corner.greenComponent, 0.95)
    }

    func testEveryDrawingToolHasAnIconAndHelp() {
        for tool in EditorTool.allCases {
            XCTAssertTrue(tool.symbol != nil || tool.mmIcon != nil, tool.rawValue)
            XCTAssertFalse(tool.help.isEmpty, tool.rawValue)
        }
        XCTAssertEqual(Set(EditorTool.allCases.map(\.rawValue)).count, EditorTool.allCases.count)
    }
}
