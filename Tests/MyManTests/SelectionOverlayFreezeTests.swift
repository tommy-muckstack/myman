import XCTest
import AppKit
@testable import MyMan

final class SelectionOverlayFreezeTests: XCTestCase {
    /// The frozen frame must stay visible inside the selection: the live
    /// screen never shows through the rectangle being picked, and the
    /// outside is clearly darker than the pick.
    @MainActor func testSelectionKeepsTheFrozenFrameInsideTheRectangle() throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let size = CGSize(width: 200, height: 120)
        let frozenImage = NSImage(size: size, flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let composite = CompositeCapture(image: frozenImage, combinedFrame: CGRect(origin: .zero, size: size), scaleFactor: 1)
        let coordinator = SelectionOverlayCoordinator(frozenCapture: nil)
        let view = SelectionOverlayView(screenFrame: CGRect(origin: .zero, size: size), coordinator: coordinator, frozenCapture: composite)
        view.updateSelection(start: CGPoint(x: 50, y: 30), current: CGPoint(x: 150, y: 90))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let inside = try XCTUnwrap(bitmap.colorAt(x: 100, y: 60))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10))
        XCTAssertGreaterThan(inside.alphaComponent, 0.99, "inside the selection is opaque frozen content, not a hole")
        XCTAssertGreaterThan(inside.redComponent, 0.9)
        XCTAssertGreaterThan(outside.alphaComponent, 0.99)
        XCTAssertLessThan(outside.redComponent, 0.5, "outside is dimmed well below the frozen frame")
    }
}

final class CaptureSoundTests: XCTestCase {
    func testEveryNamedSoundShipsInTheBundle() throws {
        for sound in CaptureSound.allCases where sound != .silent {
            let url = try XCTUnwrap(sound.url, sound.label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(sound.label) missing at \(url.path)")
            XCTAssertNotNil(NSSound(contentsOf: url, byReference: true), "\(sound.label) is not a playable sound")
        }
        XCTAssertNil(CaptureSound.silent.url)
        XCTAssertNil(CaptureSound(rawValue: "nonsense"))
    }
}
