import AppKit
import CoreImage
import GRDB
import XCTest
@testable import MyMan

final class AgentV07Tests: XCTestCase {
    @MainActor func testComparisonFindsChangesAndIgnoresOnlySpecifiedPixels() throws {
        let size = CGSize(width: 320, height: 200)
        func image(changed: Bool) throws -> NSImage {
            try AgentMediaStore.canvas(size: size) { context in
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
                if changed { context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 40, y: 150, width: 20, height: 20)) }
            }
        }
        let a = try image(changed: false), b = try image(changed: true)
        let acg = try XCTUnwrap(a.cgImage(forProposedRect: nil, context: nil, hints: nil)), bcg = try XCTUnwrap(b.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try AgentComparison.difference(acg, bcg, ignored: [], threshold: 20)
        XCTAssertEqual(result.changed, 400); XCTAssertEqual(result.compared, 64000)
        XCTAssertTrue(result.regions.contains { $0.contains(CGPoint(x: 50, y: 40)) }, "Image coordinates use top-left")
        let ignored = CGRect(x: 40, y: 30, width: 20, height: 20)
        let clean = try AgentComparison.difference(acg, bcg, ignored: [ignored], threshold: 20)
        XCTAssertEqual(clean.changed, 0); XCTAssertEqual(clean.compared, 63600)
        let render = try AgentComparison.render(before: a, after: b, difference: result, ignored: [])
        try AgentImages.png(render).write(to: URL(fileURLWithPath: "/private/tmp/man-v07-comparison.png"))
        XCTAssertEqual(try AgentComparison.difference(acg, acg, ignored: [], threshold: 0).changed, 0)
        let small = try AgentMediaStore.canvas(size: CGSize(width: 10, height: 10)) { _ in }
        XCTAssertThrowsError(try AgentComparison.difference(acg, XCTUnwrap(small.cgImage(forProposedRect: nil, context: nil, hints: nil)), ignored: [], threshold: 20))
    }
    @MainActor func testVisionWordTargetsSelectPriceInsteadOfEntireLine() async throws {
        let image = try AgentMediaStore.canvas(size: CGSize(width: 900, height: 180)) { context in
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 900, height: 180))
            ("Upgrade costs $49 today" as NSString).draw(at: CGPoint(x: 30, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        let observations = await ImageAnalysis.textObservations(image), size = AgentImages.size(image)
        let lines = AgentMarkup.regions(observations, size: size), words = AgentMarkup.words(observations, size: size)
        let price = try XCTUnwrap(words.first { $0.text == "$49" })
        let line = try XCTUnwrap(lines.first { $0.text.contains("$49") })
        XCTAssertLessThan(price.rect.width, line.rect.width / 2)
        let selection = try AgentMarkup.resolve(["type": "circle", "target_text": "$49"], regions: lines + words, size: size)
        let target = try AgentImages.rect(XCTUnwrap(selection["rect"] as? [Double]))
        XCTAssertTrue(target.contains(price.rect)); XCTAssertLessThan(target.width, line.rect.width / 2)
        let data = try JSONEncoder().encode(observations)
        XCTAssertEqual(try JSONDecoder().decode([ImageAnalysis.TextObservation].self, from: data).first?.words?.count, observations.first?.words?.count)
    }
    @MainActor func testFontQualitySeparatesEvidenceFromInferenceAndRecommendsSpecificLetters() {
        let project: [String: Any] = ["provenance": [["char":"A","source":"traced"],["char":"x","source":"traced"],["char":"q","source":"inferred"]],
            "state": ["samples": [["char":"A","confidence":95.0,"bbox":["h":50.0]], ["char":"x","confidence":95.0,"bbox":["h":12.0]]]]]
        let result = AgentFonts.quality(project: project, text: "AxqZ")
        let chars = result["characters"] as! [[String: Any]]
        let statuses = Dictionary(uniqueKeysWithValues: chars.map { ($0["char"] as! String, $0["status"] as! String) })
        XCTAssertEqual(statuses, ["A":"supported","x":"weak_sample","q":"approximate","Z":"missing"])
        XCTAssertEqual(Set(result["capture_next"] as! [String]), Set(["x","q","Z"]))
        XCTAssertEqual(result["heuristic"] as? Bool, true)
    }
    func testReadinessRequiresCurrentOCRAndNeverReportsExcludedItemsReady() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png"); try Data([1,2,3]).write(to: file)
        try db.write { db in try db.execute(sql:"INSERT INTO screenshot(id,path,createdAt) VALUES('ready',?,?)", arguments:[file.path,Date()]) }
        XCTAssertEqual(try AgentReadiness.item("shot-ready", stage: "ocr", database: db, root: root)["ready"] as? Bool, false)
        try db.write { db in try db.execute(sql:"INSERT INTO captureOCR(itemID,lines,imageVersion) VALUES('shot-ready',?,?)", arguments:[Data("[]".utf8),OCRStore.version(file)]) }
        XCTAssertEqual(try AgentReadiness.item("shot-ready", stage: "ocr", database: db, root: root)["ready"] as? Bool, true, "An empty successful OCR result is ready")
        XCTAssertEqual(try AgentReadiness.item("shot-ready", stage: "indexed", database: db, root: root)["ready"] as? Bool, false)
        try db.write { try $0.execute(sql:"DELETE FROM capturePending WHERE id='shot-ready'") }
        XCTAssertEqual(try AgentReadiness.item("shot-ready", stage: "indexed", database: db, root: root)["ready"] as? Bool, true)
        try Data([1,2,3,4]).write(to: file)
        XCTAssertEqual(try AgentReadiness.item("shot-ready", stage: "ocr", database: db, root: root)["ready"] as? Bool, false)
        XCTAssertThrowsError(try AgentReadiness.item("shot-ready", stage: "transcript", database: db, root: root))
        try db.write { try $0.execute(sql:"UPDATE captureItem SET excluded=1 WHERE id='shot-ready'") }
        XCTAssertThrowsError(try AgentReadiness.item("shot-ready", stage: "file", database: db, root: root))
    }
    @MainActor func testVideoTimelineValidatesAndRedactsBeforeZoom() throws {
        let size = CGSize(width: 320, height: 200), source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        let inputs: [[String: Any]] = [["type":"redact","start":0.0,"end":1.0,"rect":[40.0,30.0,40.0,40.0]],
            ["type":"zoom","start":0.0,"end":1.0,"rect":[40.0,30.0,40.0,40.0]]]
        let edits = try AgentVideoEdits.prepare(inputs, size: size, duration: 2)
        let context = CIContext()
        let output = try XCTUnwrap(context.createCGImage(AgentVideoEdits.render(source, time: 0.5, edits: edits), from: source.extent))
        XCTAssertTrue(try AgentComparison.pixels(output).enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 }, "Zoom never reveals redacted pixels")
        let later = try XCTUnwrap(context.createCGImage(AgentVideoEdits.render(source, time: 1, edits: edits), from: source.extent))
        XCTAssertGreaterThan(try AgentComparison.pixels(later)[0], 200, "Intervals are end-exclusive")
        XCTAssertThrowsError(try AgentVideoEdits.prepare(inputs + [inputs[1]], size: size, duration: 2))
        XCTAssertThrowsError(try AgentVideoEdits.prepare([["type":"caption","start":0.0,"end":3.0,"text":"No"]], size: size, duration: 2))
        XCTAssertThrowsError(try AgentVideoEdits.prepare([["type":"redact","start":0.0,"end":1.0,"rect":[300.0,0.0,80.0,20.0]]], size: size, duration: 2))
    }
}
