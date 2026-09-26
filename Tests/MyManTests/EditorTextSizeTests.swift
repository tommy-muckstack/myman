import AppKit
import XCTest
@testable import MyMan

final class EditorTextSizeTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let image = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        return EditorModel(image: image, fileURL: URL(fileURLWithPath: "/tmp/text-size-fixture.png"),
                           persistPreferences: false)
    }

    @MainActor func testChangingSelectedTextKeepsOtherSizesAndUpdatesBoundsAndExport() throws {
        MM.Fonts.registerFonts()
        let model = model(), first = UUID(), second = UUID(), third = UUID()
        model.setAnnotationColor(.black, selected: nil)
        model.setTextSize(14, selected: nil)
        model.add(.text(id: first, string: "Text size", origin: CGPoint(x: 30, y: 30)))
        model.add(.text(id: second, string: "Text size", origin: CGPoint(x: 30, y: 180)))
        let smallBounds = model.bounds(of: model.annotations[1])
        model.setTextSize(48, selected: second)
        model.add(.text(id: third, string: "Next", origin: CGPoint(x: 30, y: 350)))
        XCTAssertEqual(model.textSize(for: first), 14)
        XCTAssertEqual(model.textSize(for: second), 48)
        XCTAssertEqual(model.textSize(for: third), 48)
        let largeBounds = model.bounds(of: model.annotations[1])
        XCTAssertGreaterThan(largeBounds.width, smallBounds.width * 2)
        XCTAssertGreaterThan(largeBounds.height, smallBounds.height * 2)
        XCTAssertEqual(model.hitTest(CGPoint(x: largeBounds.maxX - 2, y: largeBounds.midY), tolerance: 0), second)

        let image = model.renderFinal()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: AgentImages.png(image)))
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        func inkCount(in rows: Range<Int>) -> Int {
            var count = 0
            for y in Int(CGFloat(rows.lowerBound) * scale)..<Int(CGFloat(rows.upperBound) * scale) {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 {
                        count += 1
                    }
                }
            }
            return count
        }
        let smallInk = inkCount(in: 20..<100), largeInk = inkCount(in: 170..<300)
        XCTAssertGreaterThan(smallInk, 0)
        XCTAssertGreaterThan(largeInk, smallInk * 4, "The saved image must use each text's chosen size")
        model.remove(second)
        XCTAssertNil(model.annotationFontSizes[second])
    }

    @MainActor func testExplicitSizesSurviveNewDefaultsAndNonTextSelection() {
        let model = model(), text = UUID(), shape = UUID()
        model.annotationFontSizes[text] = 36
        model.add(.text(id: text, string: "Explicit", origin: .zero))
        model.add(.box(id: shape, rect: CGRect(x: 50, y: 50, width: 30, height: 30)))
        model.setTextSize(64, selected: shape)
        XCTAssertNil(model.annotationFontSizes[shape])
        XCTAssertEqual(model.textSize(for: text), 36)
        XCTAssertEqual(model.textSize(), 64)
        model.setTextSize(.nan, selected: text)
        XCTAssertEqual(model.textSize(for: text), 36)
    }
}
