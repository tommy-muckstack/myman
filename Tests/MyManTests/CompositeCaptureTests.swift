import XCTest
import AppKit
@testable import MyMan

final class CompositeCaptureTests: XCTestCase {
    private func solidImage(_ color: NSColor, width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) throws -> NSColor {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func assertSolid(_ image: NSImage, _ expected: NSColor, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let midX = cg.width / 2
        for (name, y) in [("top", 1), ("middle", cg.height / 2), ("bottom", cg.height - 2)] {
            let color = try pixel(image, x: midX, y: y)
            XCTAssertGreaterThan(color.alphaComponent, 0.99, "\(label): \(name) row is transparent canvas, not screen pixels", file: file, line: line)
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.02, "\(label): \(name) row", file: file, line: line)
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.02, "\(label): \(name) row", file: file, line: line)
        }
    }

    /// A shorter Retina laptop beside a taller 1x monitor whose bottom edge
    /// sits below the laptop's. Every display's slice must come back whole:
    /// the laptop used to land shifted, with a blank band on top and its
    /// bottom cut off, because the composite flipped y while drawing into a
    /// bottom-left-origin context.
    func testEachDisplayCropsBackWholeWhenHeightsAndOffsetsDiffer() throws {
        let laptop = CGRect(x: 0, y: 0, width: 150, height: 100)
        let monitor = CGRect(x: 150, y: -40, width: 200, height: 140)
        let layers = [
            CompositeCapture.Layer(image: try solidImage(.red, width: 300, height: 200), frame: laptop, scaleFactor: 2),
            CompositeCapture.Layer(image: try solidImage(.blue, width: 200, height: 140), frame: monitor, scaleFactor: 1),
        ]
        let combined = laptop.union(monitor)
        let composite = try XCTUnwrap(CompositeCapture.compose(layers, combinedFrame: combined, scaleFactor: 2))
        XCTAssertEqual(composite.combinedFrame, CGRect(x: 0, y: -40, width: 350, height: 140))

        let laptopSlice = try XCTUnwrap(composite.crop(to: laptop))
        XCTAssertEqual(laptopSlice.size, laptop.size)
        try assertSolid(laptopSlice, .red, "laptop")

        let monitorSlice = try XCTUnwrap(composite.crop(to: monitor))
        XCTAssertEqual(monitorSlice.size, monitor.size)
        try assertSolid(monitorSlice, .blue, "monitor")

        // A selection straddling the seam keeps each side where the user saw it.
        let straddle = try XCTUnwrap(composite.crop(to: CGRect(x: 140, y: 10, width: 20, height: 40)))
        XCTAssertEqual(try pixel(straddle, x: 5, y: 40).redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(try pixel(straddle, x: 35, y: 40).blueComponent, 1, accuracy: 0.02)
    }

    /// Tops aligned is the other common arrangement; the shorter display
    /// still has to occupy the top of its column, not the bottom.
    func testShorterDisplayWithAlignedTopsIsNotMirrored() throws {
        let laptop = CGRect(x: 0, y: 40, width: 150, height: 100)
        let monitor = CGRect(x: 150, y: 0, width: 200, height: 140)
        let layers = [
            CompositeCapture.Layer(image: try solidImage(.red, width: 150, height: 100), frame: laptop, scaleFactor: 1),
            CompositeCapture.Layer(image: try solidImage(.blue, width: 200, height: 140), frame: monitor, scaleFactor: 1),
        ]
        let composite = try XCTUnwrap(CompositeCapture.compose(layers, combinedFrame: laptop.union(monitor), scaleFactor: 1))
        try assertSolid(try XCTUnwrap(composite.crop(to: laptop)), .red, "laptop")
        // The gap below the laptop is empty canvas, not misplaced laptop pixels.
        let gap = try XCTUnwrap(composite.crop(to: CGRect(x: 0, y: 0, width: 150, height: 40)))
        XCTAssertLessThan(try pixel(gap, x: 75, y: 20).alphaComponent, 0.01)
    }
}
