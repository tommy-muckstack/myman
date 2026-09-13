import XCTest
import AppKit
@testable import MyMan

final class BackgroundRemovalTests: XCTestCase {
    @MainActor private func sample(_ color: NSColor, fadedEdge: Bool = false) throws -> CGImage {
        let image = try AgentMediaStore.canvas(size: CGSize(width: 640, height: 240)) { ctx in
            ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 20, y: 20, width: 140, height: 200))
            ctx.fill(CGRect(x: 240, y: 150, width: 240, height: 60))
            ctx.fill(CGRect(x: 520, y: 20, width: 100, height: 200))
            // Same color enclosed within a panel must survive.
            ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 40, y: 80, width: 70, height: 40))
            if fadedEdge { ctx.clear(CGRect(x: 0, y: 0, width: 640, height: 1)); ctx.setAlpha(0.22); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 1)) }
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    private func alphas(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height)
        let ctx = try XCTUnwrap(CGContext(data: &result, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return result
    }
    @MainActor func testWhiteAndColoredSurroundsBecomeTransparentWithoutErasingEnclosedContent() throws {
        for (color, fadedEdge) in [(NSColor.white, false), (NSColor(red: 0.95, green: 0.79, blue: 0.17, alpha: 1), false), (NSColor(red: 0.95, green: 0.79, blue: 0.17, alpha: 1), true)] {
            let original = try sample(color, fadedEdge: fadedEdge), output = try XCTUnwrap(BackgroundRemoval.flatBackground(original))
            let alpha = try alphas(output)
            XCTAssertEqual(alpha[0], 0); XCTAssertEqual(alpha[120 * 640 + 320], 0)
            XCTAssertEqual(alpha[120 * 640 + 25], 255)
            XCTAssertEqual(alpha[140 * 640 + 60], 255, "An enclosed background-colored region remains opaque")
            XCTAssertEqual(try alphas(original)[0], 255)
            XCTAssertEqual(output.width, original.width); XCTAssertEqual(output.height, original.height)
        }
    }
    @MainActor func testEditorExportsTransparencyAndUndoRestoresBackdrop() async throws {
        let original = NSImage(cgImage: try sample(.white), size: CGSize(width: 640, height: 240))
        let model = EditorModel(image: original, fileURL: URL(fileURLWithPath: "/private/tmp/man-background-test.png"), persistPreferences: false)
        model.backdrop = .slate; model.removeBackground()
        for _ in 0..<100 where model.isRemovingBackground { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(model.backgroundRemoved); XCTAssertNil(model.backgroundRemovalError)
        XCTAssertEqual(model.backdrop, .none)
        let png = try AgentImages.png(model.renderFinal())
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        XCTAssertEqual(try alphas(decoded)[0], 0, "PNG export retains alpha instead of filling slate")
        model.applyCrop(CGRect(x: 0, y: 0, width: 600, height: 220)); model.undo(); XCTAssertTrue(model.backgroundRemoved)
        model.undo(); XCTAssertTrue(model.image === original); XCTAssertEqual(model.backdrop, .slate)
    }
    @MainActor func testBlankCanvasDoesNotBecomeAnEmptyCutout() throws {
        let image = try AgentMediaStore.canvas(size: CGSize(width: 100, height: 100)) { ctx in ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        XCTAssertNil(BackgroundRemoval.flatBackground(try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))))
    }
    func testOptInPrivateScreenshotFixtures() throws {
        guard let input = ProcessInfo.processInfo.environment["MYMAN_BACKGROUND_FIXTURES"] else { throw XCTSkip("Private screenshots are opt-in and never committed") }
        let paths = try JSONDecoder().decode([String].self, from: Data(input.utf8))
        for (index, path) in paths.enumerated() {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
            let original = try XCTUnwrap(rep.cgImage), result = try XCTUnwrap(BackgroundRemoval.flatBackground(original))
            let alpha = try alphas(result)
            XCTAssertEqual(alpha[0], 0)
            XCTAssertGreaterThan(alpha.filter { $0 == 0 }.count, alpha.count / 3)
            XCTAssertGreaterThan(alpha.filter { $0 == 255 }.count, alpha.count / 8)
            let out = NSBitmapImageRep(cgImage: result)
            try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-background-fixture-\(index).png"))
        }
    }
}
