import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class CursorEffectsTests: XCTestCase {
    private func samples(_ points: [(CGFloat, CGFloat)]) -> [CursorEffectsModel.TrailPoint] {
        let start = Date()
        return points.enumerated().map { index, point in
            CursorEffectsModel.TrailPoint(position: CGPoint(x: point.0, y: point.1),
                                          time: start.addingTimeInterval(Double(index) / 60))
        }
    }

    /// Left-right scrubbing over a button, sampled at 60 Hz.
    private func scrub(around center: CGPoint, reach: CGFloat, passes: Int) -> [(CGFloat, CGFloat)] {
        (0..<(passes * 8)).map { step in
            let phase = Double(step) / 8 * .pi
            return (center.x + reach * CGFloat(sin(phase)), center.y + CGFloat(step % 3))
        }
    }

    func testBackAndForthScrubHighlightsTheArea() throws {
        let area = try XCTUnwrap(CursorEffectsModel.shakeArea(
            in: samples(scrub(around: CGPoint(x: 400, y: 300), reach: 60, passes: 5))))
        XCTAssertTrue(area.contains(CGPoint(x: 400, y: 300)))
        XCTAssertGreaterThanOrEqual(area.width, 120)
        XCTAssertGreaterThanOrEqual(area.height, 40)
        XCTAssertLessThan(area.width, 220)
    }

    func testOrdinaryMovementIsNotAShake() {
        // A straight drag across the screen.
        let line = (0..<40).map { (CGFloat($0) * 20, CGFloat(200)) }
        XCTAssertNil(CursorEffectsModel.shakeArea(in: samples(line)))
        // One back-and-forth is just correcting an overshoot.
        let overshoot = scrub(around: CGPoint(x: 400, y: 300), reach: 60, passes: 2)
        XCTAssertNil(CursorEffectsModel.shakeArea(in: samples(overshoot)))
        // Tiny hand jitter never adds up to a shake.
        let jitter = (0..<40).map { (CGFloat(400 + ($0 % 2) * 6), CGFloat(300)) }
        XCTAssertNil(CursorEffectsModel.shakeArea(in: samples(jitter)))
        // Wide sweeps are travel, even when they reverse.
        let sweeps = scrub(around: CGPoint(x: 800, y: 300), reach: 400, passes: 5)
        XCTAssertNil(CursorEffectsModel.shakeArea(in: samples(sweeps)))
    }

    func testVerticalShakeCounts() {
        let vertical = scrub(around: CGPoint(x: 400, y: 300), reach: 50, passes: 5).map { ($0.1, $0.0) }
        XCTAssertNotNil(CursorEffectsModel.shakeArea(in: samples(vertical)))
    }

    @MainActor func testPenAndBoxStrokesAndFade() {
        let model = CursorEffectsModel()
        model.tool = .pen
        model.beginStroke(at: CGPoint(x: 10, y: 10))
        for x in stride(from: 12, through: 80, by: 4) { model.extendStroke(to: CGPoint(x: CGFloat(x), y: 10)) }
        model.endStroke(at: CGPoint(x: 80, y: 30))
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertGreaterThan(model.annotations[0].points.count, 10)

        model.tool = .box
        model.beginStroke(at: CGPoint(x: 100, y: 100))
        model.extendStroke(to: CGPoint(x: 150, y: 140))
        model.endStroke(at: CGPoint(x: 200, y: 180))
        XCTAssertEqual(model.annotations.last?.tool, .box)
        XCTAssertEqual(model.annotations.last?.points, [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 180)])

        // A click without a drag leaves nothing behind.
        model.beginStroke(at: CGPoint(x: 300, y: 300))
        model.endStroke(at: CGPoint(x: 301, y: 300))
        XCTAssertEqual(model.annotations.count, 2)

        model.fadeAnnotations()
        XCTAssertTrue(model.annotations.allSatisfy { $0.fadeStarted != nil })
        // Strokes that are fading can't be extended.
        model.extendStroke(to: CGPoint(x: 500, y: 500))
        XCTAssertEqual(model.annotations.last?.points.last, CGPoint(x: 200, y: 180))
    }

    @MainActor func testControlBarFitsItsPanelWithDrawTools() {
        MM.Fonts.registerFonts()
        let bar = NSHostingView(rootView: RecordingControlBar(
            elapsed: "12:08", webcamOn: true, drawTool: .pen,
            onCamera: {}, onMicrophone: {}, onStop: {}, onRestart: {}))
        let ideal = bar.fittingSize
        XCTAssertLessThanOrEqual(ideal.width, RecordingControlPlacement.size.width + 0.5)
    }
}
