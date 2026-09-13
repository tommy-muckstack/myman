import XCTest
import GRDB
import AppKit
import SwiftUI
@testable import MyMan

final class CaptureLibraryTests: XCTestCase {
    @MainActor func testOpeningThemeClearsPreviousFiltersAndShowsEveryContentType() async throws {
        _ = NSApplication.shared
        let queue = try database()
        try note(queue, id: "themed", title: "Design notes", body: "Notes")
        try note(queue, id: "unrelated", body: "Other work")
        try await queue.write { db in
            let date = Date(timeIntervalSince1970: 100)
            try db.execute(sql: "INSERT INTO screenshot(id,path,createdAt) VALUES('s','/tmp/theme-test.png',?)", arguments: [date])
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt) VALUES('m','Design review',?)", arguments: [date])
            try db.execute(sql: "INSERT INTO recording(id,path,duration,createdAt) VALUES('r','/tmp/theme-test.mov',10,?)", arguments: [date])
            try db.execute(sql: "INSERT INTO dictation(id,text,createdAt) VALUES('d','Design idea',?)", arguments: [date])
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('design','Design review','design review')")
            for id in ["note-themed", "shot-s", "meeting-m", "recording-r", "dictation-d"] {
                try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('design',?)", arguments: [id])
            }
        }
        let controls = CaptureLibraryFilters()
        controls.kind = "note"; controls.actionKind = "screenshot"
        controls.period = "today"; controls.pinned = true
        var mode = CaptureLibraryMode.themes
        var query = "Design"
        let model = CaptureLibraryModel(database: queue)
        let host = NSHostingView(rootView: CaptureLibraryView(
            query: Binding(get: { query }, set: { query = $0 }),
            mode: Binding(get: { mode }, set: { mode = $0 }), controls: controls, model: model))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 440)
        host.layoutSubtreeIfNeeded()
        defer { model.cancel() }
        for _ in 0..<100 where model.themes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.themes.map(\.id), ["design"])
        NotificationCenter.default.post(name: .captureLibraryCommand, object: "open")
        for _ in 0..<100 where model.results.count != 5 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(mode, .search); XCTAssertEqual(query, "")
        XCTAssertEqual(controls.displayedKind, "all"); XCTAssertEqual(controls.period, "any")
        XCTAssertFalse(controls.pinned); XCTAssertEqual(controls.themeID, "design")
        XCTAssertEqual(Set(model.results.map(\.id)), Set(["note-themed", "shot-s", "meeting-m", "recording-r", "dictation-d"]))
        // Moving over the screenshot shortcut while reading a theme must not
        // hide the theme's notes, dictation, meetings or recordings.
        controls.actionKind = "screenshot"
        XCTAssertEqual(controls.displayedKind, "all")
        let themed = try CaptureIndex.history(filter: CaptureFilter(kind: controls.displayedKind, themeID: controls.themeID), database: queue)
        XCTAssertEqual(Set(themed.map(\.kind)), Set(["note", "screenshot", "meeting", "recording", "dictation"]))
        // A deliberate filter-menu choice can still narrow a theme.
        controls.kind = "note"
        XCTAssertEqual(controls.displayedKind, "note")
        withExtendedLifetime(host) {}
    }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        return queue
    }
    private func note(_ queue: DatabaseQueue, id: String, title: String = "", body: String, date: Date = Date()) throws {
        try queue.write { try $0.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)", arguments: [id,title,body,date,date]) }
    }
    func testMigrationPreservesExistingSourcesAndIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue, upTo: "v13-recording-transcript")
        try note(queue, id: "old", title: "An explicit title", body: "Original personal text")
        try Database.migrator.migrate(queue)
        try Database.migrator.migrate(queue)
        let item = try XCTUnwrap(CaptureIndex.item("note-old", database: queue))
        XCTAssertEqual(item.rawTitle, "An explicit title")
        XCTAssertEqual(item.body, "Original personal text")
        XCTAssertEqual(try CaptureIndex.lexical("personal", database: queue).count, 1)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capturePending") }, 1)
    }
    func testAllSourcesAndMeetingNotesAreIndexed() throws {
        let queue = try database()
        try queue.write { db in
            let date = Date()
            try db.execute(sql: "INSERT INTO screenshot(id,path,ocrText,createdAt) VALUES(?,?,?,?)", arguments: ["s", "/tmp/pricing-page.png", "HuddleUp registration costs $49", date])
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript,summary) VALUES(?,?,?,?,?)", arguments: ["m", "Team discussion", date, "We mentioned MCP integration", "Final decision: annual subscriptions"])
            try db.execute(sql: "INSERT INTO recording(id,path,duration,createdAt,transcript) VALUES(?,?,?,?,?)", arguments: ["r", "/tmp/demo.mov", 10, date, "Webhook registration demo"])
            try db.execute(sql: "INSERT INTO dictation(id,text,createdAt) VALUES(?,?,?)", arguments: ["d", "Dictated registration ideas", date])
        }
        for (query, expected, reason) in [("$49", "shot-s", "Matched screenshot text"), ("MCP", "meeting-m", "Matched meeting transcript"), ("annual", "meeting-m", "Matched meeting notes"), ("demo.mov", "recording-r", "Matched filename"), ("Dictated", "dictation-d", "Matched title")] {
            let match = try XCTUnwrap(CaptureIndex.lexical(query, database: queue).first)
            XCTAssertEqual(match.id, expected); XCTAssertEqual(match.reason, reason)
        }
        XCTAssertEqual(try CaptureIndex.lexical("registration", filter: CaptureFilter(kind: "screenshot"), database: queue).map(\.id), ["shot-s"])
        XCTAssertEqual(try CaptureIndex.lexical("$", database: queue).count, 1)
    }
    func testStrictRankingPhraseAndTypoTolerance() throws {
        let queue = try database()
        try note(queue, id: "title", title: "HuddleUp payments", body: "Planning", date: Date(timeIntervalSince1970: 0))
        try note(queue, id: "body", title: "Yesterday", body: "Discuss HuddleUp payments today")
        try note(queue, id: "prefix", title: "Other", body: "HuddleUp paymentsystem")
        let exact = try CaptureIndex.lexical("HuddleUp payments", database: queue)
        XCTAssertEqual(exact.map(\.id), ["note-title", "note-body", "note-prefix"])
        XCTAssertEqual(try CaptureIndex.lexical("\"HuddleUp payments\"", database: queue).count, 2)
        let typo = try CaptureIndex.expanded("HuddleUp paymnets", lexical: [], semantic: false, database: queue)
        XCTAssertTrue(typo.contains { $0.id == "note-title" })
        var semantic = try XCTUnwrap(exact.last); semantic.tier = 4; semantic.score = 100
        XCTAssertEqual(CaptureIndex.rank([semantic] + exact, limit: 10).first?.id, "note-title")
    }
    func testEditAndDeleteRemoveEveryDerivedArtifact() throws {
        let queue = try database()
        try note(queue, id: "source", body: "Secret before redaction")
        try note(queue, id: "peer", body: "Another item")
        try queue.write { db in
            try db.execute(sql: "UPDATE captureItem SET generatedTitle = 'Secret label', userTitle = 'My title', pinned = 1 WHERE id = 'note-source'")
            try db.execute(sql: "INSERT INTO captureChunk VALUES('note-source',0,'body','Secret before redaction',X'0102')")
            try db.execute(sql: "INSERT INTO captureOCR VALUES('note-source',X'5B5D','version')")
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('t','Private theme','private theme')")
            try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('t','note-source')")
            try db.execute(sql: "INSERT INTO captureRelation VALUES('note-source','note-peer',0.9,'shared_entities','Secret')")
            try db.execute(sql: "INSERT INTO searchClick(query,hitID,kind,clickedAt) VALUES('Secret','note-source','note',?)", arguments: [Date()])
            try db.execute(sql: "UPDATE note SET body = 'Public after redaction' WHERE id = 'source'")
        }
        XCTAssertTrue(try CaptureIndex.lexical("Secret", database: queue).isEmpty)
        let fresh = try XCTUnwrap(CaptureIndex.item("note-source", database: queue))
        XCTAssertEqual(fresh.userTitle, "My title"); XCTAssertTrue(fresh.pinned)
        XCTAssertEqual(fresh.generatedTitle, ""); XCTAssertEqual(fresh.revision, 2)
        try queue.write { try $0.execute(sql: "DELETE FROM note WHERE id = 'source'") }
        for table in ["captureChunk", "captureOCR", "captureThemeMember", "captureRelation", "searchClick"] {
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") }, 0, table)
        }
        XCTAssertNil(CaptureIndex.item("note-source", database: queue))
        XCTAssertTrue(try CaptureIndex.lexical("Public", database: queue).isEmpty)
        try queue.write { try $0.execute(sql: "INSERT INTO capture_fts(capture_fts, rank) VALUES('integrity-check',1)") }
    }
    func testHiddenItemsStayOutOfSearchAndRelations() throws {
        let queue = try database()
        try note(queue, id: "a", body: "Private pricing discussion")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO captureChunk VALUES('note-a',0,'body','Private',X'00')")
            try db.execute(sql: "UPDATE captureItem SET excluded = 1 WHERE id = 'note-a'")
        }
        XCTAssertTrue(try CaptureIndex.lexical("pricing", database: queue).isEmpty)
        XCTAssertTrue(try CaptureIndex.history(database: queue).isEmpty)
        XCTAssertEqual(try CaptureIndex.history(filter: CaptureFilter(includeExcluded: true), database: queue).count, 1)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM captureChunk") }, 0)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capturePending") }, 0)
    }
    func testThemesAreConservativeStableAndRespectCorrections() throws {
        let queue = try database()
        for id in ["1", "2"] { try note(queue, id: id, title: "HuddleUp payments", body: "Registration pricing") }
        func infer() throws { try queue.write { db in try ThemeStore.infer(in: db, items: CaptureItem.fetchAll(db), enabled: true) } }
        try infer(); XCTAssertTrue(try ThemeStore.list(database: queue).isEmpty)
        try note(queue, id: "3", title: "HuddleUp payments", body: "Registration pricing")
        try infer()
        let theme = try XCTUnwrap(ThemeStore.list(database: queue).first)
        XCTAssertEqual(try ThemeStore.list(database: queue).count, 1)
        try ThemeStore.rename(theme.id, title: "My payment work", database: queue)
        // Direct correction avoids scheduling the production singleton in tests.
        try queue.write { try $0.execute(sql: "UPDATE captureThemeMember SET manual = 1, blocked = 1 WHERE themeID = ? AND itemID = 'note-1'", arguments: [theme.id]) }
        try infer(); try infer()
        let result = try XCTUnwrap(ThemeStore.list(database: queue).first)
        XCTAssertEqual(result.id, theme.id); XCTAssertEqual(result.title, "My payment work"); XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try CaptureIndex.history(filter: CaptureFilter(themeID: theme.id), database: queue).count, 2)
    }
    func testOCRGeometryAndLongTranscriptChunks() throws {
        let line = ImageAnalysis.TextObservation(text: "$49 per month", box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1))
        let decoded = try JSONDecoder().decode(ImageAnalysis.TextObservation.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded.id, line.id); XCTAssertEqual(decoded.text, line.text)
        XCTAssertEqual(decoded.rect(in: CGSize(width: 1000, height: 500)).minY, 100, accuracy: 0.001)
        let queue = try database()
        try note(queue, id: "long", title: "Useful explicit title", body: String(repeating: "Transcript context ", count: 300) + "MCP at the very end")
        let item = try XCTUnwrap(CaptureIndex.item("note-long", database: queue))
        XCTAssertTrue(CaptureEnrichment.chunks(item).contains { $0.1.contains("MCP at the very end") })
        XCTAssertEqual(CaptureEnrichment.generatedTitle(item), "")
        var screenshot = item
        screenshot.kind = "screenshot"; screenshot.rawTitle = ""; screenshot.body = "Man search redesign"
        XCTAssertEqual(CaptureEnrichment.generatedTitle(screenshot), "Man search redesign")
        XCTAssertTrue(ConceptThemes.fallback([screenshot]).isEmpty)
    }

    func testNaturalQueriesAndExplicitFilters() throws {
        let resolved = CaptureQuery.resolve("I screenshotted a pricing page sometime last week", filter: CaptureFilter())
        XCTAssertEqual(resolved.text, "pricing"); XCTAssertEqual(resolved.filter.kind, "screenshot")
        XCTAssertNotNil(resolved.filter.after); XCTAssertNotNil(resolved.filter.before)
        XCTAssertEqual(CaptureQuery.resolve("I remember somebody mentioning MCP in a meeting", filter: CaptureFilter()).text, "mcp")
        XCTAssertEqual(CaptureQuery.resolve("Find the screenshot where the number was $49", filter: CaptureFilter()).text, "$49")
        XCTAssertEqual(CaptureQuery.resolve("Man search redesign", filter: CaptureFilter()).text, "Man search redesign")
        XCTAssertEqual(CaptureQuery.resolve("Find that screenshot from yesterday", filter: CaptureFilter(kind: "meeting")).filter.kind, "meeting")
        XCTAssertEqual(CaptureQuery.resolve("\"Find that screenshot\"", filter: CaptureFilter()).text, "\"Find that screenshot\"")
    }

    func testThemeMergeDismissAndRelatedItemsUseCorrectionsImmediately() throws {
        let queue = try database()
        for id in ["a", "b", "c"] { try note(queue, id: id, body: "Independent \(id)", date: Date(timeIntervalSince1970: Double(id.utf8.first!) * 86400)) }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('one','First theme','first theme'),('two','Second theme','second theme')")
            try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('one','note-a'),('one','note-b'),('two','note-c')")
        }
        XCTAssertEqual(try RelatedItems.items(for: "note-a", database: queue).first?.kind, "same_theme")
        try ThemeStore.assign("note-b", to: "one", remove: true, database: queue)
        XCTAssertTrue(try RelatedItems.items(for: "note-a", database: queue).isEmpty)
        try ThemeStore.merge("one", into: "two", database: queue)
        XCTAssertEqual(try ThemeStore.list(database: queue).map(\.id), ["two"])
        XCTAssertEqual(try RelatedItems.items(for: "note-a", database: queue).first?.id, "note-c")
        try ThemeStore.dismiss("two", database: queue)
        XCTAssertTrue(try RelatedItems.items(for: "note-a", database: queue).isEmpty)
    }

    func testSemanticMatchesCannotDisplaceExactTextAndRespectFilters() throws {
        let queue = try database()
        let query = "registration pricing"
        guard let vector = SearchService.embedding(for: query) else { throw XCTSkip("Local English embedding is unavailable on this test host") }
        try note(queue, id: "exact", title: query, body: "Explicit title", date: Date(timeIntervalSince1970: 0))
        try note(queue, id: "meaning", title: "Costs", body: "Plans and subscriptions")
        try queue.write { try $0.execute(sql: "INSERT INTO captureChunk VALUES('note-meaning',0,'note text','Plans and subscriptions',?)", arguments: [vector]) }
        let lexical = try CaptureIndex.lexical(query, database: queue)
        let results = try CaptureIndex.expanded(query, lexical: lexical, database: queue)
        XCTAssertEqual(results.first?.id, "note-exact")
        XCTAssertEqual(results.last?.id, "note-meaning"); XCTAssertEqual(results.last?.tier, 4)
        XCTAssertTrue(try CaptureIndex.expanded(query, filter: CaptureFilter(kind: "screenshot"), lexical: [], database: queue).isEmpty)
    }

    func testParagraphsKeepSeparateColumnsSeparate() {
        let a = ImageAnalysis.TextObservation(text: "First line", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04))
        let b = ImageAnalysis.TextObservation(text: "Second line", box: CGRect(x: 0.1, y: 0.745, width: 0.3, height: 0.04))
        let c = ImageAnalysis.TextObservation(text: "Other column", box: CGRect(x: 0.6, y: 0.69, width: 0.3, height: 0.04))
        let groups = OCRStore.paragraphs([a,b,c])
        XCTAssertEqual(groups.count, 2); XCTAssertEqual(groups[0].text, "First line\nSecond line")
        XCTAssertEqual(groups[0].box, a.box.union(b.box))
    }

    func testLexicalLatencyWithFiveThousandCaptures() throws {
        let queue = try database()
        try queue.write { db in
            for index in 0..<5000 {
                try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)", arguments: ["\(index)", "Capture \(index)", "HuddleUp pricing discussion \(index) " + String(repeating: "Meeting context. ", count: 50), Date(), Date()])
            }
        }
        let start = Date()
        let matches = try CaptureIndex.lexical("HuddleUp pricing", database: queue)
        let elapsed = Date().timeIntervalSince(start)
        print("Man lexical search, 5,000 captures: \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(matches.count, 50); XCTAssertLessThan(elapsed, 1.0)
    }

    @MainActor func testRenderNativeSearchAndThemesFixtures() throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let queue = try database()
        for index in 0..<3 { try note(queue, id: "\(index)", title: "HuddleUp payments", body: "Registration pricing is $49 per month.\nDiscuss the rollout and billing changes.") }
        try queue.write { db in
            let items = try CaptureItem.fetchAll(db)
            let theme = ConceptThemes.Proposal(title: "Designing registration payments", description: "Registration pricing, billing choices, and the payment rollout.", members: Set(items.map(\.id)), digest: "semantic:fixture")
            try ThemeStore.infer(in: db, items: items, enabled: true, prepared: [theme])
        }
        let model = CaptureLibraryModel(database: queue)
        model.results = try CaptureIndex.lexical("pricing", database: queue)
        model.themes = try ThemeStore.list(database: queue)
        model.matchingThemeIDs = Set(model.themes.map(\.id)); model.selectedID = model.results.first?.id
        func render<V: View>(_ view: V, name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: 620, height: 500).background(MM.Colors.background))
            host.frame = NSRect(x: 0, y: 0, width: 620, height: 500)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/man-ui-\(name).png"))
            XCTAssertGreaterThan(png.count, 1000)
        }
        try render(CaptureLibraryView(query: .constant("pricing"), mode: .constant(.search), model: model), name: "search")
        try render(CaptureLibraryView(query: .constant(""), mode: .constant(.themes), model: model), name: "themes")
        let line = ImageAnalysis.TextObservation(text: "$49 per month", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))
        try render(ZStack {
            VStack(alignment: .leading, spacing: 12) { Text("HuddleUp registration").font(MM.Fonts.title); Text("$49 per month").font(MM.Fonts.body); Spacer() }.padding(40)
            OCRLocationOverlay(lines: [line], query: "$49", selected: nil)
        }.foregroundStyle(MM.Colors.textPrimary), name: "ocr-geometry")
        model.cancel()
    }

    @MainActor func testRenderScreenshotTextPreviewWithPersistedGeometry() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let queue = try database()
        let image = NSImage(size: NSSize(width: 800, height: 500), flipped: true) { bounds in
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            ("HuddleUp registration" as NSString).draw(at: NSPoint(x: 70, y: 70), withAttributes: [.font: NSFont(name: "Gellix-Medium", size: 32)!, .foregroundColor: NSColor.labelColor])
            ("$49 per month" as NSString).draw(at: NSPoint(x: 70, y: 160), withAttributes: [.font: NSFont(name: "Gellix-Regular", size: 28)!, .foregroundColor: NSColor.labelColor])
            ("https://huddleup.example/pricing" as NSString).draw(at: NSPoint(x: 70, y: 250), withAttributes: [.font: NSFont(name: "Gellix-Regular", size: 22)!, .foregroundColor: NSColor.labelColor])
            return true
        }
        let source = URL(fileURLWithPath: "/private/tmp/man-preview-source.png")
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:])).write(to: source)
        let lines = [
            ImageAnalysis.TextObservation(text: "HuddleUp registration", box: CGRect(x: 70.0/800, y: 1-108.0/500, width: 400.0/800, height: 38.0/500)),
            ImageAnalysis.TextObservation(text: "$49 per month", box: CGRect(x: 70.0/800, y: 1-194.0/500, width: 230.0/800, height: 34.0/500)),
            ImageAnalysis.TextObservation(text: "https://huddleup.example/pricing", box: CGRect(x: 70.0/800, y: 1-278.0/500, width: 430.0/800, height: 28.0/500))
        ]
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO screenshot(id,path,ocrText,createdAt) VALUES('preview',?,?,?)", arguments: [source.path, lines.map(\.text).joined(separator: "\n"), Date()])
            try db.execute(sql: "INSERT INTO captureOCR VALUES('shot-preview',?,?)", arguments: [try JSONEncoder().encode(lines), OCRStore.version(source)])
        }
        let item = try XCTUnwrap(CaptureIndex.item("shot-preview", database: queue))
        let host = NSHostingView(rootView: CaptureDetailView(item: item, query: "$49", database: queue))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 650); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-ui-screenshot-preview.png"))
        XCTAssertEqual(OCRStore.lines(itemID: item.id, database: queue).count, 3)
        window.contentView = nil; window.close()
    }
}
