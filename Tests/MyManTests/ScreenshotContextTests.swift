import AppKit
import XCTest
import SwiftUI
import GRDB
@testable import MyMan

final class ScreenshotContextTests: XCTestCase {
    private func image() -> NSImage {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(NSColor.black.cgColor)
        for x in stride(from: 0, to: 800, by: 200) { ctx.fill(CGRect(x: x, y: 0, width: 100, height: 600)) }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 800, height: 600))
    }
    private func fixture() throws -> DatabaseQueue {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        try db.write { db in
            let start = Date(timeIntervalSince1970: 1_789_135_200)
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,endedAt,transcript,summary) VALUES('call','Product demo',?,?,?,?)", arguments: [start, start.addingTimeInterval(3600), "Jordan reviews the Job Board", "Product walkthrough"])
            for (id, delta) in [("before", -1), ("during", 100), ("end", 3600)] {
                try db.execute(sql: "INSERT INTO screenshot(id,path,ocrText,createdAt) VALUES(?,?,?,?)", arguments: [id, "/tmp/\(id).png", "Job Board", start.addingTimeInterval(Double(delta))])
            }
        }
        return db
    }
    func testProminentHeadingBeatsSearchChromeAndUserTitleIsPreserved() throws {
        let lines = [ImageAnalysis.TextObservation(text: "Q, Search Tekmetric...", box: CGRect(x: 0.02, y: 0.9, width: 0.6, height: 0.1)), ImageAnalysis.TextObservation(text: "Job Board", box: CGRect(x: 0.3, y: 0.7, width: 0.3, height: 0.06)), ImageAnalysis.TextObservation(text: "Repair Guide", box: CGRect(x: 0.01, y: 0.6, width: 0.1, height: 0.015))]
        XCTAssertEqual(ScreenshotIntelligence.title(text: lines.map(\.text).joined(separator: "\n"), lines: lines), "Job Board")
        let db = try fixture()
        try db.write { db in
            try db.execute(sql: "UPDATE captureItem SET userTitle='My own comparison' WHERE id='shot-during'")
            try ScreenshotContext.saveAnalysis(.init(analysisJSON: "{}", thumbnail: nil, title: "Job Board"), itemID: "shot-during", version: "v1", in: db)
        }
        XCTAssertEqual(try CaptureIndex.item("shot-during", database: db)?.title, "My own comparison")
    }
    func testHeuristicHintsDoNotTreatDatesOrJobBoardAsPIIOrConfidential() {
        let image = image()
        let plain = ScreenshotIntelligence.analyze(text: "Job Board September 11, 2026 2026-09-11", lines: [], image: image)
        XCTAssertEqual(plain.contains_pii, "not_detected"); XCTAssertEqual(plain.contains_confidential, "not_detected")
        XCTAssertTrue(plain.tags.contains { $0.name == "web-app" })
        let sensitive = ScreenshotIntelligence.analyze(text: "SECTION 2.2\nConfidential board presentation\nAlex alex@example.com 617-555-0123", lines: [], image: image)
        XCTAssertEqual(sensitive.contains_pii, "likely"); XCTAssertEqual(sensitive.contains_confidential, "likely")
        XCTAssertTrue(sensitive.tags.contains { $0.name == "slide-deck" && $0.confidence < 1 })
        XCTAssertEqual(ScreenshotIntelligence.analyze(text: "", lines: [], image: image).contains_pii, "unknown")
        let thumbnail = ScreenshotIntelligence.thumbnail(image).flatMap(NSBitmapImageRep.init(data:))
        XCTAssertEqual(thumbnail?.pixelsWide, 400); XCTAssertEqual(thumbnail?.pixelsHigh, 300)
        let hash = ScreenshotIntelligence.differenceHash(image)!
        XCTAssertTrue(ScreenshotIntelligence.similar(hash, hash))
        XCTAssertFalse(ScreenshotIntelligence.similar("0000000000000000", "0000000000000000"))
    }
    func testMeetingLinksHaveCorrectBoundariesAndDisappearWithExcludedMeeting() throws {
        let db = try fixture()
        var snapshot = try db.read { try BrainAgentExport.snapshot(in: $0) }
        let call = snapshot.catalog.exports.first { $0.kind == "meetings" }!
        XCTAssertEqual(call.screenshots?.count, 1)
        let shot = snapshot.catalog.exports.first { $0.path.contains("during") }!
        XCTAssertEqual(shot.meetings?.map(\.association), ["time_overlap"])
        XCTAssertTrue(snapshot.documents[shot.path]!.contains("ocr_text: |-\n  Job Board"))
        try db.write { db in
            try ScreenshotContext.saveOrigin(.init(itemID: "shot-during", timezone: "America/New_York", meetingID: "call"), in: db)
        }
        snapshot = try db.read { try BrainAgentExport.snapshot(in: $0) }
        let linked = snapshot.catalog.exports.first { $0.path == shot.path }!
        XCTAssertEqual(linked.meetings?.first?.association, "recorded_during")
        XCTAssertEqual(linked.timezone_source, "capture"); XCTAssertTrue(linked.captured_local!.hasSuffix("-04:00"))
        try db.write { try $0.execute(sql: "UPDATE captureItem SET excluded=1 WHERE id='meeting-call'") }
        snapshot = try db.read { try BrainAgentExport.snapshot(in: $0) }
        XCTAssertTrue(snapshot.catalog.exports.first { $0.path == shot.path }!.meetings!.isEmpty)
    }
    func testOriginAndDerivedDataMergeAndDeletionCascades() throws {
        let db = try fixture()
        try db.write { db in
            try ScreenshotContext.saveAnalysis(.init(analysisJSON: "{}", thumbnail: Data([1,2]), title: "Job Board"), itemID: "shot-during", version: "v1", in: db)
            try ScreenshotContext.saveOrigin(.init(itemID: "shot-during", timezone: "America/New_York", meetingID: "call", app: "Chrome"), in: db)
        }
        let context = try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during") }!
        XCTAssertEqual(context.thumbnail, Data([1,2])); XCTAssertEqual(context.app, "Chrome")
        try db.write { try $0.execute(sql: "DELETE FROM meeting WHERE id='call'") }
        XCTAssertNil(try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during")?.meetingID })
        try db.write { try $0.execute(sql: "UPDATE captureItem SET excluded=1 WHERE id='shot-during'") }
        XCTAssertNil(try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during") })
        try db.write { db in try ScreenshotContext.saveAnalysis(.init(analysisJSON: "{}", thumbnail: Data([3]), title: "Hidden"), itemID: "shot-during", version: "v2", in: db) }
        XCTAssertNil(try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during") })
    }
    func testSelectedWindowMetadataDoesNotLeakOccludedOrOtherApp() {
        let hidden = CaptureWindowSnapshot.Window(bounds: CGRect(x: 0, y: 0, width: 400, height: 400), app: "", bundleID: "", title: "", url: "")
        let background = CaptureWindowSnapshot.Window(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), app: "Chrome", bundleID: "com.google.Chrome", title: "Job Board", url: "")
        let snapshot = CaptureWindowSnapshot(windows: [hidden, background])
        XCTAssertNil(snapshot.selected(in: CGRect(x: 20, y: 400, width: 100, height: 100), mainDisplayHeight: 600))
        XCTAssertEqual(snapshot.selected(in: CGRect(x: 500, y: 100, width: 100, height: 100), mainDisplayHeight: 600)?.app, "Chrome")
    }
    func testOptOutAndAppExclusionPreventLateOriginWrites() throws {
        let db = try fixture()
        let origin = ScreenshotContext(itemID: "shot-during", timezone: "America/New_York", app: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Private window title", url: "https://example.com/private")
        try db.write { db in
            try ScreenshotContext.saveOrigin(origin, in: db)
            try ScreenshotContext.clearWindowDetails(excludedApps: "Chrome", in: db)
            try ScreenshotContext.saveOrigin(origin, in: db, metadataEnabled: false)
        }
        let context = try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during") }!
        XCTAssertTrue(context.app.isEmpty); XCTAssertTrue(context.windowTitle.isEmpty); XCTAssertTrue(context.url.isEmpty)
        try db.write { try ScreenshotContext.saveOrigin(origin, in: $0, excludedApps: "com.google.Chrome") }
        XCTAssertEqual(try db.read { try ScreenshotContext.fetchOne($0, key: "shot-during")?.app }, "")
    }

    func testExportedThumbnailAndMetadataCanFeedTheBundledCompanion() throws {
        let db = try fixture(), id = "A0000000-0000-0000-0000-000000000001"
        let prepared = try ScreenshotContext.prepare(image: image(), lines: [], text: "Job Board\nRepair order estimates")
        try db.write { db in
            let date = try Date.fetchOne(db, sql: "SELECT startedAt FROM meeting WHERE id='call'")!.addingTimeInterval(200)
            try db.execute(sql: "INSERT INTO screenshot(id,path,ocrText,createdAt) VALUES(?,?,?,?)", arguments: [id, "/tmp/example.png", "Job Board\nRepair order estimates", date])
            try ScreenshotContext.saveOrigin(.init(itemID: "shot-" + id, timezone: "America/New_York", meetingID: "call", app: "Google Chrome"), in: db)
            try ScreenshotContext.saveAnalysis(prepared, itemID: "shot-" + id, version: "v1", in: db)
        }
        let source = try db.read { try BrainAgentExport.source(in: $0) }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAN_VISUAL_EXPORT_FIXTURE"] ?? "/private/tmp/man-visual-fixture-unused")
        let snapshot = BrainAgentExport.snapshot(source: source, root: root)
        let entry = snapshot.catalog.exports.first { $0.thumbnail_path != nil }!
        XCTAssertTrue(entry.thumbnail_path!.hasPrefix(root.path + "/assets/capture-thumbnails/"))
        XCTAssertEqual(entry.tags?.first?.name, "web-app")
        if ProcessInfo.processInfo.environment["MAN_VISUAL_EXPORT_FIXTURE"] != nil {
            for (path, text) in snapshot.documents {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            for (path, data) in snapshot.assets {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try JSONEncoder().encode(snapshot.catalog).write(to: root.appendingPathComponent("catalog.json"))
        }
        try db.write { try $0.execute(sql: "DELETE FROM screenshot WHERE id=?", arguments: [id]) }
        XCTAssertTrue(try db.read { try BrainAgentExport.snapshot(in: $0).assets }.isEmpty)
    }

    @MainActor func testRenderCaptureMetadataPreferences() throws {
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let preferences = UserDefaults(suiteName: "man.capture-context-test")!
        preferences.removePersistentDomain(forName: "man.capture-context-test")
        defer { preferences.removePersistentDomain(forName: "man.capture-context-test") }
        preferences.set(true, forKey: "captureWindowMetadata")
        let host = NSHostingView(rootView: CapturePrivacySettings().defaultAppStorage(preferences).frame(width: 600, height: 630).background(MM.Colors.background))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 630); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-capture-context-settings.png"))
    }

}
