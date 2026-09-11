import XCTest
import GRDB
@testable import MyMan

final class MeetingGroundingTests: XCTestCase {
    private let transcript = """
    **You** [0:04]: I'll send the deck links tomorrow so you can review the pricing changes.

    **Jamie** [0:30]: We should explore robotics one day, but we haven't decided on a plan.

    **You** [2:00]: Just between us, I have an interview onsite in October. Please keep this private.

    **Jamie** [2:30]: Good luck with the interview and the presentation.

    **You** [6:00]: The report should arrive by email after the user finishes the audit.
    """

    func testEvidenceBindsSpeakerQuoteAndTimestampTogether() {
        let index = TranscriptIndex(transcript: transcript)
        XCTAssertFalse(index.supports(owner: "Jamie", timestamp: "0:04"))
        let sources = Dictionary(uniqueKeysWithValues: MeetingSource.parse(transcript).map { ($0.id, $0) })
        let fact = MeetingFact(sourceID: 1, text: "Will send the deck links tomorrow.", quote: "I'll send the deck links tomorrow", importance: 3)
        XCTAssertEqual(MeetingEvidence.fact(fact, sources: sources)?.sourceID, 0)
        // Provenance follows the unique quote, never an unreliable model id.
        XCTAssertNil(MeetingEvidence.source(for: "An invented sentence with no source", in: sources))
        XCTAssertFalse(MeetingEvidence.groundedWording("Robotics will replace email", in: "The report arrives by email."))
        XCTAssertFalse(MeetingEvidence.groundedWording("Revenue reached $100 million", in: "Revenue reached $10 million"))
    }

    func testPrivacyIsRemovedBeforeDerivedExtractionButOriginalIsUntouched() {
        let raw = MeetingSource.parse(transcript)
        let safe = MeetingSource.publicTurns(raw)
        XCTAssertFalse(safe.contains { $0.text.localizedCaseInsensitiveContains("interview") })
        XCTAssertEqual(safe.map(\.id), [0, 1, 4])
        XCTAssertTrue(raw[2].text.contains("onsite"))
        XCTAssertEqual(MeetingSource.publicTurns(MeetingSource.parse("You:\nThis is confidential: a password.")), [])
    }

    func testOnlyKnownOwnersAndExplicitCommitmentsBecomeActions() {
        let turns = MeetingSource.parse(transcript).map {
            MeetingSourceTurn(id: $0.id, speaker: $0.speaker == "You" ? "Alex" : $0.speaker, timestamp: $0.timestamp, text: $0.text)
        }
        let sources = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        var action = MeetingCommitment(sourceID: 0, owner: "Alex", task: "Send the deck links", quote: "I'll send the deck links tomorrow", due: "tomorrow", confidence: 0.98)
        XCTAssertNotNil(MeetingEvidence.commitment(action, sources: sources))
        action.due = "chat"
        XCTAssertEqual(MeetingEvidence.commitment(action, sources: sources)?.due, "")
        XCTAssertFalse(MeetingEvidence.isTaskTitle("Share the information"))
        XCTAssertTrue(DueDate.isTemporalExpression("by 2026-09-16"))
        XCTAssertFalse(DueDate.isTemporalExpression("launch"))
        action.owner = "Jamie"
        XCTAssertNil(MeetingEvidence.commitment(action, sources: sources))
        action.owner = "Speaker 3"
        XCTAssertNil(MeetingEvidence.commitment(action, sources: sources))
        action = MeetingCommitment(sourceID: 1, owner: "Jamie", task: "Explore robotics", quote: "We should explore robotics one day", due: "", confidence: 1)
        XCTAssertNil(MeetingEvidence.commitment(action, sources: sources))
        XCTAssertNil(TaskHygiene.cleanQuotedTask("\"I'm a fairly big risk taker.\""))
        XCTAssertEqual(TaskHygiene.cleanQuotedTask("\"I'll follow up with the partner about rate limits.\""), "Follow up with the partner about rate limits.")
    }

    func testBleedIsDeduplicatedButOwnerInterruptionsRemain() {
        let remote = MeetingTurn(start: 0, end: 25, speaker: "Speaker 2", text: "The best way to measure the report is to instrument the whole registration funnel and track each step.")
        let echo = MeetingTurn(start: 0.4, end: 25.4, speaker: "You", text: remote.text)
        let listening = MeetingChannelDedupe.clean(mic: [echo], system: [remote])
        XCTAssertEqual(listening.kind, .listening)
        XCTAssertTrue(listening.mic.isEmpty)
        XCTAssertEqual(listening.system.first?.text, remote.text)
        let interruption = MeetingTurn(start: 12, end: 14, speaker: "You", text: "Wait, which report?")
        let call = MeetingChannelDedupe.clean(mic: [echo, interruption], system: [remote])
        XCTAssertEqual(call.kind, .meeting)
        XCTAssertEqual(call.mic.map(\.text), [interruption.text])
        var later = echo; later.start = 3600; later.end = 3625
        XCTAssertEqual(MeetingChannelDedupe.clean(mic: [later], system: [remote]).mic.count, 1)
    }

    func testTurnBoundsAndSpeakerChangesArePreserved() {
        let turns = (0..<8).map { MeetingTurn(start: Double($0 * 20), end: Double($0 * 20 + 20), speaker: "You", text: String(repeating: "word ", count: 100)) }
        for turn in MeetingController.mergeConsecutive(turns) {
            XCTAssertLessThanOrEqual(turn.end - turn.start, 45)
            XCTAssertLessThanOrEqual(turn.text.count, 1200)
        }
        let intervals = MeetingController.speakerIntervals(speech: [(0, 30)], voices: [("A", 0, 10), ("B", 10, 30)])
        XCTAssertEqual(intervals.map(\.speaker), ["Speaker 2", "Speaker 3"])
        XCTAssertEqual(intervals.map(\.start), [0, 10])
        XCTAssertFalse(MeetingSource.isBackchannel("Zürich"))
        XCTAssertTrue(MeetingSource.isBackchannel("Uh huh. Hmm."))
    }

    func testListeningExportHasNoActionsAndEnrichesCalendarIdentity() throws {
        var meeting = Meeting(id: "listening", title: "An interview", startedAt: Date(), transcript: "**Speaker 1** [0:03]: Growth comes from solving the customer's problem.")
        meeting.kind = "listening"
        let turn = try XCTUnwrap(MeetingSource.parse(meeting.transcript).first)
        let fact = MeetingFact(sourceID: 0, text: "Growth comes from solving the customer's problem.", quote: turn.text, importance: 3)
        meeting.summary = GroundedMeetingNotes.render(facts: [fact], actions: [MeetingCommitment(sourceID: 0, owner: "Alex", task: "Build the product", quote: turn.text, due: "", confidence: 1)], sources: [0: turn], meeting: meeting, privateOmitted: false)
        let exported = Brain.meetingMarkdown(meeting)
        XCTAssertTrue(exported.contains("kind: listening"))
        XCTAssertTrue(exported.contains("## Takeaways"))
        XCTAssertFalse(exported.contains("Action items"))
        XCTAssertFalse(exported.contains("You"))
        meeting.transcript = "**You** [0:00]: Hello.\n\n**Jamie** [0:04]: Hello."
        meeting.ownerName = "Alex Smith"
        meeting.participantsJSON = String(decoding: try JSONEncoder().encode([MeetingParticipant(name: "Jamie Lee", email: "jamie@example.com")]), as: UTF8.self)
        let enriched = Brain.meetingMarkdown(meeting)
        XCTAssertTrue(enriched.contains("Alex Smith"))
        XCTAssertTrue(enriched.contains("Jamie Lee <jamie@example.com>"))
    }

    func testApprovedVocabularyAuditsCorrectionsAndLeavesRawTextAlone() {
        let source = "Let's use Stonebot for this report, not robotics."
        let fixed = MeetingVocabulary.correct(source, terms: [], aliases: ["Stonebot": "StoneBot"])
        XCTAssertEqual(fixed.corrections, ["Stonebot → StoneBot"])
        XCTAssertTrue(fixed.text.contains("StoneBot"))
        XCTAssertTrue(source.contains("Stonebot"))
        let multiword = MeetingVocabulary.correct("Ask Jamie Lee about Stone Bot.", terms: ["Jamie Lee", "StoneBot"])
        XCTAssertEqual(multiword.text, "Ask Jamie Lee about StoneBot.")
        XCTAssertEqual(multiword.corrections, ["Stone Bot. → StoneBot."])
        XCTAssertFalse(MeetingSource.isBackchannel("language"))
    }

    func testMigrationArchivesFragmentsAndKeepsTheirDeletionLink() throws {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue, upTo: "v14-unified-retrieval")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meeting (id, title, startedAt, transcript) VALUES ('legacy', 'Weekly', ?, ?)", arguments: [Date(), transcript])
            try db.execute(sql: "INSERT INTO task (id, title, source, done, createdAt) VALUES ('fragment', ?, 'meeting', 0, ?)", arguments: ["\"I'll send the deck links tomorrow so you can review the pricing changes.\"", Date()])
            try db.execute(sql: "INSERT INTO task (id, title, source, done, createdAt) VALUES ('manual', 'Buy groceries', 'manual', 0, ?)", arguments: [Date()])
        }
        try Database.migrator.migrate(queue)
        try queue.write { db in
            let fragment = try XCTUnwrap(TaskItem.fetchOne(db, key: "fragment"))
            XCTAssertTrue(fragment.archived)
            XCTAssertEqual(fragment.sourceMeetingID, "legacy")
            XCTAssertEqual(try Meeting.fetchOne(db, key: "legacy")?.originalTranscript, transcript)
            try Meeting.deleteOne(db, key: "legacy")
            XCTAssertNil(try TaskItem.fetchOne(db, key: "fragment"))
            XCTAssertEqual(try TaskItem.fetchOne(db, key: "manual")?.title, "Buy groceries")
        }
    }

    func testTaskStorageIsIdempotentAndDeletionCascades() throws {
        let queue = try DatabaseQueue(); try Database.migrator.migrate(queue)
        var meeting = Meeting(id: "source", title: "Weekly", startedAt: Date(), transcript: transcript)
        meeting.ownerName = "Alex Smith"
        let action = MeetingCommitment(sourceID: 0, owner: "Alex", task: "Send the deck links", quote: "I'll send the deck links tomorrow", due: "tomorrow", confidence: 0.98)
        try queue.write { db in
            try meeting.insert(db)
            try TaskHygiene.store([action, action], meeting: meeting, in: db)
            try TaskHygiene.store([action], meeting: meeting, in: db)
            XCTAssertEqual(try TaskItem.fetchCount(db), 1)
            try MeetingVocabulary.record(meeting, in: db)
            try Meeting.deleteOne(db, key: meeting.id)
            XCTAssertEqual(try TaskItem.fetchCount(db), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM vocabularyMention"), 0)
        }
    }
}
