import XCTest
import GRDB
@testable import MyMan

final class ConceptThemeTests: XCTestCase {
    private func item(_ id: String, _ text: String, title: String = "") -> CaptureItem {
        CaptureItem(id: id, kind: "screenshot", sourceID: id, rawTitle: title, generatedTitle: "", userTitle: "", body: text, summary: "", metadata: "", sourcePath: "", capturedAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0), pinned: false, excluded: false, revision: 1)
    }
    private func vector(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        try queue.write { db in
            for id in 0..<7 {
                try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)", arguments: [String(id), "", "Example source \(id)", Date(), Date()])
            }
        }
        return queue
    }
    private func proposal(_ title: String = "Designing repair approval workflows", _ members: Set<String> = ["note-0", "note-1", "note-2"]) -> ConceptThemes.Proposal {
        .init(title: title, description: "Connecting estimates, customer authorization, and service progress.", members: members, digest: "semantic:" + members.sorted().joined(separator: ","))
    }
    private func apply(_ proposals: [ConceptThemes.Proposal], _ queue: DatabaseQueue, enabled: Bool = true, retire: Bool = true, preserve: Bool = false) throws {
        try queue.write { db in
            try ThemeStore.infer(in: db, items: CaptureItem.fetchAll(db), enabled: enabled, prepared: proposals, retireUnmatched: retire, preserveConcepts: preserve)
        }
    }

    func testNamesAndSharedNavigationDoNotBecomeConcepts() {
        let items = (0..<6).map { item(String($0), "Taylor Morgan\nSign out of account\nHome Dashboard Settings\n" + ($0 < 3 ? "Comparing vehicle repair estimates and customer approvals \($0)" : "Planning family travel flights and accommodation \($0)")) }
        let evidence = ConceptThemes.evidence(items, names: ["Taylor Morgan"], embedding: { _ in nil })
        XCTAssertEqual(evidence.count, 6)
        XCTAssertTrue(evidence.allSatisfy { !$0.text.contains("Taylor") && !$0.text.contains("Dashboard") && !$0.text.contains("Sign out") })
        XCTAssertEqual(ConceptThemes.groups(evidence).map(\.count).sorted(), [3, 3])
        XCTAssertTrue(ConceptThemes.fallback(items).isEmpty)
        let names = (0..<3).map { item(String($0), "", title: "Taylor Morgan") }
        XCTAssertTrue(ConceptThemes.fallback(names, names: ["Taylor Morgan"]).isEmpty)
    }

    func testSemanticSimilarityConnectsDifferentVocabularyWithoutMixingSubjects() {
        let texts = ["Vehicle estimate authorization", "Customer service approval", "Automotive maintenance quoting", "Family holiday accommodation", "Vacation flight itinerary", "Travel hotel reservation"]
        let evidence = texts.enumerated().map { index, text in
            ConceptThemes.Evidence(item: item(String(index), text), text: text, terms: Set(CaptureText.words(text)), vector: vector(index < 3 ? [1, 0, 0] : [0, 1, 0]))
        }
        let groups = ConceptThemes.groups(evidence)
        XCTAssertEqual(Set(groups.map { Set($0.map { $0.item.id }) }), [Set(["0", "1", "2"]), Set(["3", "4", "5"])])
        XCTAssertTrue(ConceptThemes.groups(Array(evidence.prefix(2))).isEmpty)
        let label = ConceptThemes.Label(title: "Improving vehicle repair approvals", description: "Estimate approval workflow.", supportingItems: [0, 1, 2])
        XCTAssertNotNil(ConceptThemes.proposal(label, group: groups[0], names: []))
    }

    func testDuplicateCapturesCannotManufactureATheme() {
        let items = (0..<8).map { item(String($0), "Transcribe this audio into English") }
        XCTAssertTrue(ConceptThemes.groups(ConceptThemes.evidence(items, embedding: { _ in nil })).isEmpty)
    }

    func testLabelsMustBeGroundedAndRejectOutliers() {
        let items = (0..<4).map { item(String($0), "Improving vehicle repair estimates and customer approvals") }
        let group = ConceptThemes.evidence(items, embedding: { _ in self.vector([1, 0]) })
        XCTAssertEqual(group.count, 4)
        let good = ConceptThemes.Label(title: "Improving repair estimate approvals", description: "Repair approvals.", supportingItems: [0, 1, 2, 999])
        XCTAssertEqual(ConceptThemes.proposal(good, group: group, names: [])?.members, ["0", "1", "2"])
        for title in ["Taylor Morgan", "First pass", "How much", "Scheduling meeting dates and times", "Invented aerospace investment strategy"] {
            XCTAssertNil(ConceptThemes.proposal(.init(title: title, description: "", supportingItems: [0, 1, 2]), group: group, names: ["Taylor Morgan"]))
        }
        XCTAssertNil(ConceptThemes.proposal(.init(title: good.title, description: "", supportingItems: [0, 1, 1]), group: group, names: []))
    }

    func testLegacyThemeBecomesConceptWithStableIdentityAndDescription() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO captureTheme(id,title,signature) VALUES('legacy','Repair Guide','repair guide'),('noise','first pass','first pass')")
            for id in 0..<3 { try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('legacy',?)", arguments: ["note-\(id)"]) }
            try db.execute(sql: "INSERT INTO captureThemeMember(themeID,itemID) VALUES('noise','note-6')")
        }
        try apply([proposal()], queue)
        try apply([proposal()], queue)
        let themes = try ThemeStore.list(database: queue)
        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].id, "legacy")
        XCTAssertEqual(themes[0].title, proposal().title)
        XCTAssertEqual(themes[0].description, proposal().description)
        XCTAssertEqual(themes[0].count, 3)
    }

    func testDuplicateGeneratedTitlesCombineTheirEvidence() throws {
        let queue = try database()
        try apply([proposal(), proposal(proposal().title, ["note-3", "note-4", "note-5"])], queue)
        XCTAssertEqual(try ThemeStore.list(database: queue).count, 1)
        XCTAssertEqual(try ThemeStore.list(database: queue).first?.count, 6)
    }

    func testRenamesPinsAssignmentsAndRemovalsSurviveRegrouping() throws {
        let queue = try database()
        try apply([proposal()], queue)
        let id = try XCTUnwrap(ThemeStore.list(database: queue).first?.id)
        try ThemeStore.rename(id, title: "My service design", database: queue)
        try ThemeStore.pin(id, pinned: true, database: queue)
        try ThemeStore.assign("note-0", to: id, remove: true, database: queue)
        try ThemeStore.assign("note-6", to: id, database: queue)
        try apply([proposal("Refining repair estimate approvals", ["note-0", "note-1", "note-2", "note-3"])], queue)
        let theme = try XCTUnwrap(ThemeStore.list(database: queue).first)
        XCTAssertEqual(theme.id, id); XCTAssertEqual(theme.title, "My service design")
        XCTAssertEqual(theme.count, 4)
        try apply([], queue)
        XCTAssertEqual(try ThemeStore.list(database: queue).first?.count, 4)
        XCTAssertFalse(try CaptureIndex.history(filter: CaptureFilter(themeID: id), database: queue).contains { $0.id == "note-0" })
    }

    func testDismissalAndMergeDoNotRecreateRejectedConcepts() throws {
        let queue = try database()
        try apply([proposal(), proposal("Planning travel accommodation choices", ["note-3", "note-4", "note-5"])], queue)
        let themes = try ThemeStore.list(database: queue)
        XCTAssertEqual(themes.count, 2)
        let source = try XCTUnwrap(themes.first { $0.title.contains("repair") })
        let target = try XCTUnwrap(themes.first { $0.id != source.id })
        try ThemeStore.merge(source.id, into: target.id, database: queue)
        try apply([proposal()], queue)
        XCTAssertEqual(try ThemeStore.list(database: queue).map(\.id), [target.id])
        try ThemeStore.dismiss(target.id, database: queue)
        try apply([proposal("Planning travel accommodation choices", Set((0..<6).map { "note-\($0)" }))], queue)
        XCTAssertTrue(try ThemeStore.list(database: queue).isEmpty)
    }

    func testDisabledIncompleteAndUnavailablePassesPreserveExistingConcepts() throws {
        let queue = try database()
        try apply([proposal()], queue)
        try apply([], queue, enabled: false)
        try apply([], queue, retire: false)
        try apply([], queue, preserve: true)
        XCTAssertEqual(try ThemeStore.list(database: queue).count, 1)
        try queue.write { try $0.execute(sql: "UPDATE captureItem SET excluded=1 WHERE id='note-0'") }
        try apply([proposal()], queue)
        // Excluded evidence cannot be reintroduced by a stale proposal.
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM captureThemeMember WHERE itemID='note-0'") }, 0)
    }

    func testSnapshotInvalidatesOnEditsDeletionAndExclusion() {
        let first = item("1", "Original content")
        var edited = first; edited.body = "Different content"
        let key = ConceptThemeWorker.snapshotKey([first], names: [], available: true)
        XCTAssertNotEqual(key, ConceptThemeWorker.snapshotKey([edited], names: [], available: true))
        XCTAssertNotEqual(key, ConceptThemeWorker.snapshotKey([], names: [], available: true))
        XCTAssertNotEqual(key, ConceptThemeWorker.snapshotKey([first], names: [], available: false))
    }

    /// Opt-in, private QA on a SQLite backup. Never edits the live library or
    /// logs source material. The report remains outside the repository.
    func testReviewConceptsOnPrivateCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAN_THEME_REVIEW_DATABASE"], path.hasPrefix("/private/tmp/") else { throw XCTSkip("Private-copy review is opt-in") }
        let queue = try DatabaseQueue(path: path)
        let (items, names) = try await queue.read { db in
            (try CaptureItem.filter(Column("excluded") == false).fetchAll(db), try String.fetchAll(db, sql: "SELECT name FROM person") + [NSFullUserName()])
        }
        let start = Date()
        let evidence = ConceptThemes.evidence(items, names: names)
        let groups = ConceptThemes.groups(evidence)
        print("Concept QA: \(items.count) captures, \(evidence.count) usable, \(groups.count) groups; clustering \(Date().timeIntervalSince(start)) seconds; local model available: \(ConceptThemes.modelAvailable)")
        var report: [[String: Any]] = []
        for group in groups {
            let label = await ConceptThemes.label(group)
            let proposal = label.flatMap { ConceptThemes.proposal($0, group: group, names: names) }
            report.append(["count": group.count, "title": label?.title ?? "unavailable", "description": label?.description ?? "", "accepted": proposal != nil, "members": proposal?.members.sorted() ?? [], "samples": ConceptThemes.samples(group).map { $0.text }])
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/private/tmp/man-concept-review.json"))
    }
}
