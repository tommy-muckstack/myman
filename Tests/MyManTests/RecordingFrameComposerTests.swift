import AppKit
import CoreVideo
import XCTest
@testable import MyMan

final class RecordingFrameComposerTests: XCTestCase {
    /// A solid BGRA picture, like a captured frame.
    private func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * stride + x * 4
                base[offset] = blue; base[offset + 1] = green; base[offset + 2] = red; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// The BGRA value at a pixel, as (r, g, b).
    private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]))
    }

    /// The output is the screen plus a border on every side, and both dimensions stay even.
    func testOutputIsLargerByABorderOnEachSide() {
        let composer = RecordingFrameComposer(sourceWidth: 640, sourceHeight: 360, color: .systemBlue)
        XCTAssertEqual(composer.padding, 38)
        XCTAssertEqual(composer.outputWidth, 716)
        XCTAssertEqual(composer.outputHeight, 436)
        XCTAssertEqual(composer.outputWidth % 2, 0)
        XCTAssertEqual(composer.outputHeight % 2, 0)
    }

    /// The screen sits in the middle, and the border shows the frame color.
    func testScreenIsFramedInTheChosenColor() throws {
        let composer = RecordingFrameComposer(sourceWidth: 640, sourceHeight: 360, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let source = solid(width: 640, height: 360, red: 0, green: 255, blue: 0)
        let output = try XCTUnwrap(composer.compose(source))
        XCTAssertEqual(CVPixelBufferGetWidth(output), composer.outputWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(output), composer.outputHeight)
        // The middle of the screen keeps its green.
        let middle = pixel(output, composer.outputWidth / 2, composer.outputHeight / 2)
        XCTAssertGreaterThan(middle.1, 200)
        XCTAssertLessThan(middle.0, 60)
        // Near the edge of the border, away from the card, the frame color (red) shows.
        let border = pixel(output, 4, composer.outputHeight / 2)
        XCTAssertGreaterThan(border.0, 120)
        XCTAssertLessThan(border.1, 60)
    }

    /// A picture that does not match the composer's size is skipped, not stretched.
    func testMismatchedFrameIsRejected() {
        let composer = RecordingFrameComposer(sourceWidth: 640, sourceHeight: 360, color: .systemBlue)
        XCTAssertNil(composer.compose(solid(width: 320, height: 180, red: 0, green: 0, blue: 0)))
    }
}
