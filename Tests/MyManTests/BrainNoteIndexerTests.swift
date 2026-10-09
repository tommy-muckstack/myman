import XCTest
import GRDB
@testable import MyMan

final class BrainNoteIndexerTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseQueue!
    private var indexer: BrainNoteIndexer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseQueue()
        try Database.migrator.migrate(database)
        indexer = BrainNoteIndexer(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func options() -> BrainNoteIndexer.Options {
        var options = BrainNoteIndexer.Options(root: root)
        options.skipRoots = [root.appendingPathComponent("MyManBrain")]
        options.schedulesEnrichment = false
        return options
    }

    private func rows() throws -> [BrainNote] {
        try database.read { try BrainNote.order(Column("path")).fetchAll($0) }
    }

    func testScanIndexesMarkdownAndSkipsExcludedFoldersAndBigFiles() throws {
        try write("a.md", "# Alpha note\n\nBody about pricing.")
        try write("nested/b.markdown", "---\ntitle: Beta\n---\n\nBeta body.")
        try write("finances/x.md", "# Secret")
        try write("node_modules/z.md", "# Dep")
        try write("MyManBrain/meetings/m.md", "# Exported meeting")
        try write("big.md", String(repeating: "x", count: 600 * 1024))
        try write("image.png", "not markdown")
        let report = try indexer.scan(options())
        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertGreaterThanOrEqual(report.skipped, 3)
        let notes = try rows()
        XCTAssertEqual(notes.map(\.title), ["Alpha note", "Beta"])
        XCTAssertEqual(notes.first?.body, "Body about pricing.")
        XCTAssertEqual(notes.last?.body, "Beta body.")
        let items = try database.read { try CaptureItem.filter(Column("kind") == "brainNote").order(Column("id")).fetchAll($0) }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.id.hasPrefix("brain-") && $0.sourcePath.hasSuffix(".md") || $0.sourcePath.hasSuffix(".markdown") })
        XCTAssertFalse(try CaptureIndex.lexical("pricing", database: database).isEmpty)
    }

    func testRescanIsIncrementalAndTracksEditsAndDeletes() throws {
        try write("a.md", "# Alpha\n\nfirst")
        try write("b.md", "# Beta\n\nsecond")
        XCTAssertEqual(try indexer.scan(options()).added, 2)
        let unchanged = try indexer.scan(options())
        XCTAssertEqual(unchanged.scanned, 2)
        XCTAssertEqual(unchanged.added + unchanged.updated + unchanged.removed, 0)
        try write("a.md", "# Alpha two\n\nchanged")
        let future = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: root.appendingPathComponent("a.md").path)
        let edit = try indexer.scan(options())
        XCTAssertEqual(edit.updated, 1)
        XCTAssertEqual(try rows().first?.title, "Alpha two")
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        let removal = try indexer.scan(options())
        XCTAssertEqual(removal.removed, 1)
        XCTAssertEqual(try rows().count, 1)
        let items = try database.read { try CaptureItem.filter(Column("kind") == "brainNote").fetchCount($0) }
        XCTAssertEqual(items, 1, "the capture trigger removes the item with the row")
    }

    func testHiddenFlagSurvivesARescan() throws {
        try write("a.md", "# Alpha\n\nbody")
        try indexer.scan(options())
        let item = try XCTUnwrap(try database.read { try CaptureItem.filter(Column("kind") == "brainNote").fetchOne($0) })
        try database.write { try $0.execute(sql: "UPDATE captureItem SET excluded = 1 WHERE id = ?", arguments: [item.id]) }
        try write("a.md", "# Alpha edited\n\nbody")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.appendingPathComponent("a.md").path)
        try indexer.scan(options())
        let after = try XCTUnwrap(try database.read { try CaptureItem.fetchOne($0, key: item.id) })
        XCTAssertTrue(after.excluded)
        XCTAssertEqual(after.rawTitle, "Alpha edited")
    }

    func testTitleFallsBackToFilename() {
        let parsed = BrainNote.parse(markdown: "no heading here\nsecond line", filename: "first-90-days.md")
        XCTAssertEqual(parsed.title, "first-90-days")
        XCTAssertEqual(parsed.body, "no heading here\nsecond line")
        let fm = BrainNote.parse(markdown: "---\ntype: reference\ntitle: \"Quoted Title\"\n---\n# Heading wins", filename: "x.md")
        XCTAssertEqual(fm.title, "Heading wins")
        XCTAssertFalse(fm.body.contains("type: reference"))
    }
}

final class BrainWorkspaceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func folder(_ name: String, files: [String]) throws -> URL {
        let url = home.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            let target = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: target, atomically: true, encoding: .utf8)
        }
        return url
    }

    func testPickedFolderWinsOverPointer() throws {
        let picked = try folder("picked", files: ["notes/a.md"])
        let pointed = try folder("pointed", files: ["brainz.toml"])
        let pointer = home.appendingPathComponent("workspace.json")
        try #"{"root":"\#(pointed.path)"}"#.write(to: pointer, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrainWorkspace.discover(pickedPath: picked.path, home: home, pointer: pointer)?.standardizedFileURL, picked.standardizedFileURL)
        XCTAssertEqual(BrainWorkspace.discover(pickedPath: nil, home: home, pointer: pointer)?.standardizedFileURL, pointed.standardizedFileURL)
    }

    func testDefaultBrainNeedsTomlAndEmptyFolderIsNotAWorkspace() throws {
        let empty = try folder("empty", files: [])
        XCTAssertFalse(BrainWorkspace.isWorkspace(empty))
        XCTAssertNil(BrainWorkspace.discover(pickedPath: empty.path, home: home, pointer: home.appendingPathComponent("missing.json")))
        _ = try folder("brain", files: ["README.txt"])
        XCTAssertNil(BrainWorkspace.discover(pickedPath: nil, home: home, pointer: home.appendingPathComponent("missing.json")))
        _ = try folder("brain", files: ["brainz.toml"])
        XCTAssertEqual(BrainWorkspace.discover(pickedPath: nil, home: home, pointer: home.appendingPathComponent("missing.json"))?.lastPathComponent, "brain")
    }
}
