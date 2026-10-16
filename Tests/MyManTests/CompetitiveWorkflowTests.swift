import XCTest
import GRDB
import FluidAudio
@testable import MyMan

private actor WorkflowGate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { guard !opened else { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

final class CompetitiveWorkflowTests: XCTestCase {
    func testScratchThatPreservesCompletedSentencesAndLiterals() {
        XCTAssertEqual(DictationBacktrack.apply("Keep the budget at $92,000. Send it Tuesday, scratch that Wednesday."), "Keep the budget at $92,000. Wednesday.")
        XCTAssertEqual(DictationBacktrack.apply("Keep this. Delete this. Scratch that. Replace it."), "Keep this. Replace it.")
        XCTAssertEqual(DictationBacktrack.apply("One. Two. Scratch that scratch that Three."), "Three.")
        XCTAssertEqual(DictationBacktrack.apply("Write the phrase scratch that in the guide."), "Write the phrase scratch that in the guide.")
        XCTAssertEqual(DictationBacktrack.apply("He said “scratch that” yesterday."), "He said “scratch that” yesterday.")
        XCTAssertEqual(DictationBacktrack.apply("He said 'scratch that' yesterday."), "He said 'scratch that' yesterday.")
        XCTAssertEqual(DictationBacktrack.apply("Don't lose this. Delete this scratch that Keep going."), "Don't lose this. Keep going.")
        XCTAssertEqual(DictationBacktrack.apply("First sentence. Clear this dictation. Start again."), "Start again.")
    }

    func testSnippetExpansionIsExactNonrecursiveAndLongestFirst() throws {
        var value = DictationPersonalization()
        value.snippets = [.init(cue: "my signature", expansion: "Alex\n$1 \\path https://example.com?a=1&b=2"),
                          .init(cue: "my signature code", expansion: "let x = \"my signature\"\n  print(x)"),
                          .init(cue: "hello", expansion: "my signature")]
        value.aliases = [.init(term: "ProductName", soundsLike: ["product name"])]
        _ = try value.validated()
        let plan = value.prepare("my signature code hello product name")
        XCTAssertEqual(plan.restore(plan.text), "let x = \"my signature\"\n  print(x) my signature ProductName")
        XCTAssertNil(plan.restore(plan.text.lowercased()), "Damaged placeholders must fail closed")
        let signature = value.prepare("my signature")
        XCTAssertEqual(signature.restore(signature.text), value.snippets[0].expansion)
        XCTAssertEqual(DictationPersonalization.replace("hello! shelloworld", rules: [("hello", "$1\\code")]), "$1\\code! shelloworld")
    }

    @MainActor func testMalformedImportDoesNotReplacePersonalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationPersonalizationStore(root: root)
        var value = DictationPersonalization(); value.snippets = [.init(cue: "signature", expansion: "Exact\n  whitespace")]
        try store.save(value)
        XCTAssertThrowsError(try DictationPersonalizationStore.decode(Data("{bad json}".utf8)))
        XCTAssertEqual(DictationPersonalizationStore(root: root).value, value)
        var duplicate = value; duplicate.snippets.append(.init(cue: "SIGNATURE", expansion: "other"))
        XCTAssertThrowsError(try store.save(duplicate))
        XCTAssertEqual(store.value, value)
    }

    func testRetrievalFindsLateEvidenceAndHonorsScope() throws {
        let db = try DatabaseQueue(); try Database.migrator.migrate(db)
        let date = Date(timeIntervalSince1970: 1000)
        let late = String(repeating: "Ordinary agenda discussion. ", count: 900) + "\n**Alex** [55:10]: We approved the zephyr migration for Friday."
        try db.write { db in
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript) VALUES('late','Design review',?,?)", arguments: [date, late])
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript) VALUES('other','Other review',?,'We rejected the zephyr migration.')", arguments: [date])
        }
        let retrieval = try BrainChatRetrieval.retrieve("What was decided about zephyr migration?", scope: .init(itemID: "meeting-late"), database: db)
        XCTAssertEqual(retrieval.scopedCount, 1)
        XCTAssertTrue(retrieval.sources.contains { $0.text.contains("approved the zephyr migration") && $0.offset > 10_000 })
        XCTAssertTrue(retrieval.sources.allSatisfy { $0.itemID == "meeting-late" })
        let outsideDate = try BrainChatRetrieval.retrieve("zephyr", scope: .init(after: Date(timeIntervalSince1970: 2000)), database: db)
        XCTAssertTrue(outsideDate.sources.isEmpty)
        try db.write { try $0.execute(sql: "UPDATE captureItem SET excluded = 1 WHERE id = 'meeting-late'") }
        XCTAssertTrue(try BrainChatRetrieval.retrieve("zephyr", scope: .init(itemID: "meeting-late"), database: db).sources.isEmpty)
    }

    func testFabricatedOrMisattributedCitationsAreRejected() throws {
        let source = BrainChatSource(id: "S1", itemID: "synthetic", revision: 1, title: "Review", date: Date(), field: "transcript", offset: 2000, text: "We agreed to ship on Friday, not Tuesday.")
        let retrieval = BrainChatRetrieval(sources: [source], scopedCount: 20, candidateCount: 1)
        func response(id: String, quote: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["answer": "Friday [S1]", "citations": [["sourceID": id, "quote": quote]]]), as: UTF8.self)
        }
        XCTAssertNotNil(BrainChatAnswer.validated(try response(id: "S1", quote: source.text), retrieval: retrieval))
        XCTAssertNil(BrainChatAnswer.validated(try response(id: "S2", quote: source.text), retrieval: retrieval))
        XCTAssertNil(BrainChatAnswer.validated(try response(id: "S1", quote: "We agreed to ship on Tuesday."), retrieval: retrieval))
        let unbound = try response(id: "S1", quote: source.text).replacingOccurrences(of: "Friday [S1]", with: "Friday [S99]")
        XCTAssertNil(BrainChatAnswer.validated(unbound, retrieval: retrieval))
        XCTAssertTrue(retrieval.coverage.contains("not an exhaustive audit"))
    }

    func testTemplatesPreserveTypedNotesExactlyAndKeepEvidence() {
        let body = "  - My private hypothesis\n\n`DoNotChange()`  \n"
        let note = MeetingNoteInput.PersonalNote(id: "synthetic", body: body, updatedAt: Date())
        var input = MeetingNoteInput(notes: [note]); let prior = input.fingerprint
        input.enhancePersonalNotes = true
        XCTAssertNotEqual(input.fingerprint, prior)
        let output = input.template.render("## Overview\n\nA proposal. [0:30]\n\n## Next steps\n\nNone agreed.", personalNotes: input.personalNotes)
        XCTAssertTrue(output.contains(body)); XCTAssertTrue(output.contains("[0:30]"))
        XCTAssertTrue(output.contains("not claims verified against the transcript"))
    }

    @MainActor func testLateSummaryCannotOverwriteRevisedPersonalNotesOrTemplate() async throws {
        for changeTemplate in [false, true] {
            let db = try DatabaseQueue(); try Database.migrator.migrate(db)
            let meeting = Meeting(id: UUID().uuidString, title: "Synthetic review", startedAt: Date(), transcript: "**Alex** [0:10]: I will send the draft on Friday.")
            var draft = Note(body: "Original typed note"); draft.meetingID = meeting.id
            let note = draft
            try await db.write { try meeting.insert($0); try note.insert($0) }
            let gate = WorkflowGate(), started = expectation(description: "Summary started")
            let service = MeetingNotesService(database: db) { _, _, _ in started.fulfill(); await gate.wait(); return "Old generated summary" }
            let task = Task { await service.notes(meetingID: meeting.id) }
            await fulfillment(of: [started], timeout: 2)
            if changeTemplate {
                var input = try await db.read { try MeetingNoteInput.load(meeting.id, in: $0) }
                input.template = MeetingNoteTemplate.builtins[1]
                try MeetingNoteInput.save(input, meetingID: meeting.id, database: db)
            } else {
                try await db.write { try $0.execute(sql: "UPDATE note SET body = 'New typed note' WHERE id = ?", arguments: [note.id]) }
            }
            await gate.open(); _ = await task.value
            let summary = try await db.read { try Meeting.fetchOne($0, key: meeting.id)?.summary }
            XCTAssertEqual(summary, "")
        }
    }

    func testMultipleCutsRetimeCaptionsCursorAndTitleOffset() throws {
        let edits = RecordingEditList(cuts: [.init(start: 2, end: 4), .init(start: 3, end: 5), .init(start: 8, end: 9)])
        let ranges = try edits.keptRanges(duration: 12)
        XCTAssertEqual(ranges.map { [$0.start, $0.end] }, [[0, 2], [5, 8], [9, 12]])
        XCTAssertEqual(RecordingEditList.mappedTime(10, ranges: ranges), 6)
        XCTAssertNil(RecordingEditList.mappedTime(3, ranges: ranges))
        let segments: [RecordingTranscript.Segment] = [.init(start: 0, end: 1, text: "First"), .init(start: 5, end: 7, text: "Middle"), .init(start: 10, end: 11, text: "Last")]
        let mapped = RecordingEditList.retime(segments, ranges: ranges, offset: 3)
        XCTAssertEqual(mapped.map(\.start), [3, 5, 9]); XCTAssertEqual(mapped.map(\.end), [4, 7, 10])
        XCTAssertTrue(RecordingTranscript.subtitles(mapped, webVTT: true).contains("00:00:09.000 --> 00:00:10.000"))
        XCTAssertThrowsError(try RecordingEditList(cuts: [.init(start: 0, end: 12)]).keptRanges(duration: 12))
        XCTAssertThrowsError(try RecordingEditList(cuts: [.init(start: .nan, end: 2)]).keptRanges(duration: 12))
    }

    func testCutWordsAreRemovedFromCaptionsAndEditedCaptionsFailClosed() throws {
        let words: [RecordingTranscript.Segment] = [.init(start: 0, end: 1, text: "Keep"), .init(start: 1, end: 2, text: "secret"), .init(start: 2, end: 3, text: "this.")]
        var project = RecordingProject(captions: RecordingTranscript.captions(words))
        let ranges = try RecordingEditList(cuts: [.init(start: 1, end: 2)]).keptRanges(duration: 3)
        let result = project.retimedCaptions(words: words, ranges: ranges, offset: 3)
        XCTAssertEqual(result.map(\.text).joined(separator: " "), "Keep this.")
        XCTAssertFalse(RecordingTranscript.subtitles(result, webVTT: true).contains("secret"))
        let partial = try RecordingEditList(cuts: [.init(start: 1.4, end: 1.6)]).keptRanges(duration: 3)
        XCTAssertFalse(project.retimedCaptions(words: words, ranges: partial).map(\.text).joined(separator: " ").contains("secret"))
        project.captions[0].text = "A manually rewritten sentence."
        XCTAssertTrue(project.retimedCaptions(words: words, ranges: ranges).isEmpty)
    }

    @MainActor func testExportPreservesExistingFilesAndChoosesAnotherName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("synthetic.mp4")
        let original = Data("synthetic original".utf8)
        try original.write(to: source)
        let destination = RecordingWorkspaceExport.destination(for: source)
        try Data("earlier export".utf8).write(to: destination)
        XCTAssertNotEqual(RecordingWorkspaceExport.destination(for: source), destination)
        do {
            try await RecordingWorkspaceExport.export(source: source, destination: destination, project: .init(), options: .init()) { _ in }
            XCTFail("An existing export must never be replaced")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try String(contentsOf: destination), "earlier export")
    }

    func testTimedTokensPreserveStandaloneWordBoundariesAndClampToAudio() {
        let tokens: [TokenTiming] = [
            .init(token: "▁Hello", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 1),
            .init(token: " ", tokenId: 2, startTime: 0.4, endTime: 0.5, confidence: 1),
            .init(token: "world", tokenId: 3, startTime: 0.5, endTime: 0.9, confidence: 1),
            .init(token: ".", tokenId: 4, startTime: 0.9, endTime: 1.2, confidence: 1)]
        let words = ParakeetEngine.words(from: tokens, sampleCount: 16000, offset: 25)
        XCTAssertEqual(words.map(\.text), ["Hello", "world."])
        XCTAssertEqual(words.map(\.start), [25, 25.5])
        XCTAssertEqual(words.last?.end, 26)
    }

    func testTimedSidecarsInvalidateWhenSourceChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("synthetic.mp4")
        try Data("synthetic".utf8).write(to: movie)
        try RecordingTranscript.save([.init(start: 0, end: 1, text: "Synthetic caption")], for: movie)
        XCTAssertNotNil(RecordingTranscript.load(for: movie))
        try Data("changed synthetic file".utf8).write(to: movie)
        XCTAssertNil(RecordingTranscript.load(for: movie))
    }
}
