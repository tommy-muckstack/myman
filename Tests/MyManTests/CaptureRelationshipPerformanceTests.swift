import XCTest
import GRDB
@testable import MyMan

final class CaptureRelationshipPerformanceTests: XCTestCase {
    private func item(_ id: String, _ body: String) -> CaptureItem {
        CaptureItem(id: id, kind: "note", sourceID: id, rawTitle: "", generatedTitle: "", userTitle: "",
                    body: body, summary: "", metadata: "", sourcePath: "",
                    capturedAt: Date(timeIntervalSince1970: 1000), modifiedAt: Date(timeIntervalSince1970: 1000),
                    pinned: false, excluded: false, revision: 1)
    }

    private func sorted(_ edges: [CaptureRelationships.Edge]) -> [CaptureRelationships.Edge] {
        edges.sorted { ($0.source, $0.target, $0.kind) < ($1.source, $1.target, $1.kind) }
    }

    func testUnchangedLibraryDoesNoScoringAndEditReusesUnrelatedEvidence() throws {
        var items = [item("a", "orchard apples harvest"), item("b", "orchard apples picking"),
                     item("c", "galaxy telescope planets"), item("d", "galaxy telescope stars")]
        let first = try XCTUnwrap(CaptureRelationships().prepare(items))
        XCTAssertEqual(first.analyzedItems, 4)
        XCTAssertEqual(first.edges.count, 4)
        XCTAssertNil(first.next.prepare(items))
        items[0].body += " pear"
        items[0].revision += 1
        let edit = try XCTUnwrap(first.next.prepare(items))
        XCTAssertEqual(edit.analyzedItems, 1)
        XCTAssertEqual(edit.sources, ["a", "b"])
        XCTAssertEqual(edit.scoredPairs, 2)
        let combined = first.edges.filter { !edit.sources.contains($0.source) } + edit.edges
        XCTAssertEqual(sorted(combined), sorted(try XCTUnwrap(CaptureRelationships().prepare(items)).edges))
    }

    func testIncrementalResultsMatchFreshCalculationAcrossChangesAndCandidateLimit() throws {
        var items = (0..<65).map { item(String(format: "%03d", $0), "orchard apples harvest https://orchard.example.com") }
        var state = CaptureRelationships()
        var edges: [CaptureRelationships.Edge] = []
        for step in 0..<8 {
            if step == 1 { items[0].body = "galaxy telescope planets"; items[0].revision += 1 }
            if step == 2 { items.removeFirst(12) }
            if step == 3 { items.append(item("new", "orchard apples pears")) }
            if step == 4 { items[0].generatedTitle = "orchard apples" }
            if step == 5 { items.removeAll { Int($0.id) ?? 0 > 35 } }
            if step == 6 { items.removeAll() }
            if step == 7 { items = [item("fresh-a", "nebula telescope"), item("fresh-b", "nebula telescope")] }
            let update = try XCTUnwrap(state.prepare(items))
            edges = edges.filter { !update.sources.contains($0.source) } + update.edges
            state = update.next
            XCTAssertEqual(sorted(edges), sorted(try XCTUnwrap(CaptureRelationships().prepare(items)).edges), "step \(step)")
        }
    }

    func testDatabaseTriggersAndIncrementalWritesPreserveCorrectRelationships() throws {
        let database = try DatabaseQueue()
        try Database.migrator.migrate(database)
        let worker = CaptureEnrichment(database: database)
        let initial = [item("a", "orchard apples"), item("b", "orchard apples"),
                       item("c", "galaxy telescope"), item("d", "galaxy telescope")]
        try database.write { db in for value in initial { try value.insert(db) } }
        XCTAssertNotNil(try worker.rebuildRelationships())
        XCTAssertNil(try worker.rebuildRelationships())
        try database.write { try $0.execute(sql: "UPDATE captureItem SET body = 'galaxy telescope', revision = revision + 1 WHERE id = 'a'") }
        XCTAssertNotNil(try worker.rebuildRelationships())
        try assertDatabaseMatchesFresh(database)
        try database.write { try $0.execute(sql: "UPDATE captureItem SET excluded = 1, revision = revision + 1 WHERE id = 'c'") }
        XCTAssertNotNil(try worker.rebuildRelationships())
        try assertDatabaseMatchesFresh(database)
        try database.write { try $0.execute(sql: "DELETE FROM captureItem WHERE id = 'a'") }
        XCTAssertNotNil(try worker.rebuildRelationships())
        try assertDatabaseMatchesFresh(database)
    }

    func testThousandItemLibraryOnlyRescoresAffectedGroup() throws {
        var items = (0..<1000).map { index in
            item("item-\(index)", "orchard orchardtoken\(index / 10) applekey\(index / 10)")
        }
        let first = try XCTUnwrap(CaptureRelationships().prepare(items))
        XCTAssertEqual(first.analyzedItems, 1000)
        XCTAssertEqual(first.scoredPairs, 9000)
        XCTAssertNil(first.next.prepare(items))
        items[0].body += " pears"
        items[0].revision += 1
        let edit = try XCTUnwrap(first.next.prepare(items))
        XCTAssertEqual(edit.analyzedItems, 1)
        XCTAssertEqual(edit.sources.count, 10)
        XCTAssertEqual(edit.scoredPairs, 90)
    }

    private func assertDatabaseMatchesFresh(_ database: DatabaseQueue) throws {
        let snapshot = try database.read { try CaptureItem.filter(Column("excluded") == false).fetchAll($0) }
        let expected = try XCTUnwrap(CaptureRelationships().prepare(snapshot)).edges
        let actual = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM captureRelation").map {
                CaptureRelationships.Edge(source: $0["sourceID"], target: $0["targetID"], score: $0["score"], kind: $0["kind"], reason: $0["reason"])
            }
        }
        XCTAssertEqual(sorted(actual), sorted(expected))
    }
}
