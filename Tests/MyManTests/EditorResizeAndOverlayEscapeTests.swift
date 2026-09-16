import XCTest
import AppKit
@testable import MyMan

final class EditorResizeAndOverlayEscapeTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        return EditorModel(image: image, fileURL: URL(fileURLWithPath: "/tmp/resize-fixture.png"), preferences: UserDefaults(suiteName: "resize-tests")!)
    }

    @MainActor func testCornersAndEdgesResizeABoxWhileTheBodyStillMoves() {
        let m = model()
        let id = UUID()
        m.add(.box(id: id, rect: CGRect(x: 100, y: 100, width: 100, height: 50)))
        XCTAssertEqual(m.handles(for: m.annotations[0]).count, 8)
        XCTAssertEqual(m.handle(at: CGPoint(x: 201, y: 151), for: id, tolerance: 6), .bottomRight)
        XCTAssertEqual(m.handle(at: CGPoint(x: 150, y: 99), for: id, tolerance: 6), .top)
        XCTAssertNil(m.handle(at: CGPoint(x: 150, y: 125), for: id, tolerance: 6), "the body is not a handle")
        m.resize(id, handle: .bottomRight, to: CGPoint(x: 260, y: 190))
        guard case .box(_, let grown) = m.annotations[0] else { return XCTFail() }
        XCTAssertEqual(grown, CGRect(x: 100, y: 100, width: 160, height: 90))
        m.resize(id, handle: .topLeft, to: CGPoint(x: 120, y: 110))
        guard case .box(_, let shrunk) = m.annotations[0] else { return XCTFail() }
        XCTAssertEqual(shrunk, CGRect(x: 120, y: 110, width: 140, height: 80))
        // Dragging a corner past the opposite side never flips the box.
        m.resize(id, handle: .left, to: CGPoint(x: 500, y: 0))
        guard case .box(_, let pinned) = m.annotations[0] else { return XCTFail() }
        XCTAssertEqual(pinned.width, 4); XCTAssertEqual(pinned.maxX, 260)
        m.move(id, by: CGVector(dx: -10, dy: 5))
        guard case .box(_, let moved) = m.annotations[0] else { return XCTFail() }
        XCTAssertEqual(moved.origin, CGPoint(x: 246, y: 115))
    }

    @MainActor func testArrowEndsAreHandlesAndTextHasNone() {
        let m = model()
        let arrow = UUID(), text = UUID()
        m.add(.arrow(id: arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 40)))
        m.add(.text(id: text, string: "Hi", origin: CGPoint(x: 200, y: 200)))
        XCTAssertEqual(m.handle(at: CGPoint(x: 88, y: 42), for: arrow, tolerance: 6), .arrowEnd)
        m.resize(arrow, handle: .arrowEnd, to: CGPoint(x: 120, y: 60))
        guard case .arrow(_, let from, let to) = m.annotations[0] else { return XCTFail() }
        XCTAssertEqual(from, CGPoint(x: 10, y: 10)); XCTAssertEqual(to, CGPoint(x: 120, y: 60))
        XCTAssertTrue(m.handles(for: m.annotations[1]).isEmpty)
    }

    private final class Spy: SelectionOverlayDelegate {
        var cancelled = 0, completed = 0
        func selectionOverlayDidComplete(with rect: CGRect) { completed += 1 }
        func selectionOverlayDidCancel() { cancelled += 1 }
    }

    @MainActor func testOverlayLeavesOnItsOwnWhenNothingIsPickedInTime() async throws {
        _ = NSApplication.shared
        let coordinator = SelectionOverlayCoordinator(frozenCapture: nil, idleTimeout: 0.2)
        let spy = Spy()
        coordinator.delegate = spy
        coordinator.showAll()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(spy.cancelled, 1)
        coordinator.hideAll()
        // A pick in progress is never interrupted by the idle timer.
        let busy = SelectionOverlayCoordinator(frozenCapture: nil, idleTimeout: 0.2)
        let busySpy = Spy()
        busy.delegate = busySpy
        busy.showAll()
        busy.handleSelectionStart(at: CGPoint(x: 10, y: 10))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(busySpy.cancelled, 0)
        busy.handleSelectionEnd(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(busySpy.completed, 1)
        busy.hideAll()
    }
}
