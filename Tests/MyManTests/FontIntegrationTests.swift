import XCTest
import AppKit
import WebKit
import CoreText
@testable import MyMan

final class FontIntegrationTests: XCTestCase {
    func testVisionCoordinatesAndAssetBoundary() throws {
        let box = FontRecognition.pixels(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), width: 2000, height: 1000)
        XCTAssertEqual(box.minX, 200, accuracy: 0.001); XCTAssertEqual(box.minY, 400, accuracy: 0.001)
        XCTAssertEqual(box.width, 600, accuracy: 0.001)
        let assets = FontWorkbenchAssets()
        XCTAssertNotNil(assets.resource(URL(string: "myman-font://bundle/index.html")!))
        XCTAssertNotNil(assets.resource(URL(string: "myman-font://bundle/fonts/Inter-Regular.ttf")!))
        for url in ["https://example.com/index.html", "file:///etc/hosts", "myman-font://other/index.html", "myman-font://bundle/../../etc/hosts", "myman-font://bundle/source/missing.png"] {
            XCTAssertNil(assets.resource(URL(string: url)!))
        }
        XCTAssertThrowsError(try FontProjectStore.validate(Data("not a font".utf8)))
    }
    @MainActor func testNativeWorkbenchAndWithheldFonts() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_FONT_UI_REVIEW"] else { throw XCTSkip("Set MAN_FONT_UI_REVIEW to run native WKWebView integration and export artifacts.") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (index, name) in ["HelveticaNeue", "Georgia", "Courier-Bold"].enumerated() {
            let font = try XCTUnwrap(NSFont(name: name, size: 64))
            let image = NSImage(size: NSSize(width: 1000, height: 230))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 230).fill()
            // Deliberately withhold A,B,g,2,7 and punctuation. No target outlines
            // are passed to inference; these faces are outside the matcher library.
            ("Hello Moon\nhope SOME" as NSString).draw(at: NSPoint(x: 35, y: 35), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            image.unlockFocus()
            let controller = FontWorkbenchController()
            defer { controller.window.close() }
            try controller.add(data: AgentImages.png(image), title: name)
            controller.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let deadline = Date().addingTimeInterval(30)
            while !controller.ready, controller.startupError == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertNil(controller.startupError); XCTAssertTrue(controller.ready, "Workbench failed to start: \(controller.startupError ?? "timeout")")
            guard controller.ready else { continue }
            _ = try await controller.webView.evaluateJavaScript("window.fontWorkbench.run(); void 0")
            let finish = Date().addingTimeInterval(90)
            var previous = ""
            while Date() < finish {
                let progress = try await controller.webView.callAsyncJavaScript("return window.fontWorkbench.inspect()", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
                let status = progress["status"] as? String ?? ""
                if status != previous { FileHandle.standardError.write(Data("FONT \(name): \(status)\n".utf8)); previous = status }
                if progress["ready"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            let result = try await controller.webView.callAsyncJavaScript("return window.fontWorkbench.inspect()", arguments: [:], in: nil, contentWorld: .page)
            let state = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(state["ready"] as? Bool, true, String(describing: state.keys))
            let captured = try XCTUnwrap(state["captured"] as? [String]), inferred = try XCTUnwrap(state["inferred"] as? [String])
            XCTAssertGreaterThan(captured.count, 5); XCTAssertTrue(inferred.contains("A")); XCTAssertFalse(captured.contains("A"))
            let data = try XCTUnwrap(Data(base64Encoded: state["font"] as? String ?? ""))
            try FontProjectStore.validate(data)
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).otf"))
            let glyphs = try XCTUnwrap(state["glyphs"] as? [String: [String: Any]])
            for char in ["A", "B", "g", "2", "7", "?"] { XCTAssertEqual(glyphs[char]?["source"] as? String, "inferred"); XCTAssertFalse((glyphs[char]?["path"] as? String ?? "").isEmpty) }
            for char in captured { XCTAssertEqual(glyphs[char]?["source"] as? String, "traced") }
            let blocked = try await controller.webView.callAsyncJavaScript("try { await fetch('https://example.com/'); return false; } catch { return true; }", arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(blocked as? Bool, true)
            let renamed = "Withheld \(index)"
            _ = try await controller.webView.callAsyncJavaScript("const input=document.getElementById('name'); input.value=name; input.dispatchEvent(new Event('input')); await new Promise(r=>setTimeout(r,600)); return window.fontWorkbench.inspect().name;", arguments: ["name": renamed], in: nil, contentWorld: .page)
            let screenshot = try await controller.webView.takeSnapshot(configuration: nil)
            try AgentImages.png(screenshot).write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-workbench.png"))
            _ = try await controller.webView.callAsyncJavaScript("document.getElementById('cancel').click(); return true;", arguments: [:], in: nil, contentWorld: .page)
            let ready = try await controller.webView.callAsyncJavaScript("return window.fontWorkbench.inspect().ready", arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(ready as? Bool, false)
        }
    }
}
