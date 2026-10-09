import XCTest
import GRDB
@testable import MyMan

/// Scripted provider: returns a fixed extraction (or throws) and counts calls.
final class FakeWritingProvider: WritingModelProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var responses: [Result<String, Error>]
    private(set) var calls = 0
    private(set) var requests: [WritingRequest] = []

    init(id: String = "fake:test", responses: [Result<String, Error>]) {
        self.id = id
        self.responses = responses
    }

    convenience init(extraction: HostedExtraction) {
        self.init(responses: [.success(String(decoding: try! JSONEncoder().encode(extraction), as: UTF8.self))])
    }

    func generate(_ request: WritingRequest) async throws -> WritingResult {
        lock.lock()
        calls += 1
        requests.append(request)
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        lock.unlock()
        let text = try response.get()
        return WritingResult(text: text, inputTokens: request.input.count / 4, outputTokens: text.count / 4, model: "fake")
    }
}

final class HostedMeetingNotesTests: XCTestCase {
    private let transcript = """
    **You** [0:04]: I'll send the deck links tomorrow so you can review the pricing changes.

    **Jamie** [1:00]: The registration report should be delivered by email after the audit finishes, and the audit covers the whole quarter.

    **Jamie** [2:00]: We should run a showcase for the sales team next month.

    **You** [3:00]: Sounds good, that gives us time to prepare the materials properly.
    """

    private func meeting(transcript: String? = nil) -> Meeting {
        var meeting = Meeting(id: "hosted-" + UUID().uuidString, title: "Weekly", startedAt: Date(timeIntervalSince1970: 1_789_000_000),
                              transcript: transcript ?? self.transcript)
        meeting.ownerName = "Alex Doe"
        return meeting
    }

    private func extraction(facts: [HostedExtraction.Fact] = [], commitments: [HostedExtraction.Commitment] = [], overview: String = "") -> HostedExtraction {
        HostedExtraction(facts: facts, commitments: commitments, overview: overview)
    }

    private let reportFact = HostedExtraction.Fact(sourceID: 9, quote: "registration report should be delivered by email",
                                                   text: "The registration report should be delivered by email after the audit finishes.", importance: 3, kind: "discussion")

    override func tearDown() { WritingModels.override = nil }

    func testSchemaIsStrictAndKindsMatchMeetingClaimKind() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HostedExtraction.schema.utf8)) as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["facts", "commitments", "overview"])
        let facts = ((schema["properties"] as? [String: Any])?["facts"] as? [String: Any])?["items"] as? [String: Any]
        let kind = ((facts?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(kind, MeetingClaimKind.allCases.map(\.rawValue))
        XCTAssertEqual(facts?["additionalProperties"] as? Bool, false)
        XCTAssertTrue(HostedExtraction.instructions(listening: false).contains("40 facts"))
        XCTAssertTrue(HostedExtraction.instructions(listening: true).contains("commitments MUST be an empty list"))
    }

    func testGroundedQuoteIsAcceptedWithCorrectedSourceID() async {
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact]))
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(provider.requests.first?.purpose, .meetingNotes)
        XCTAssertNotNil(provider.requests.first?.jsonSchema)
        let fact = analysis.facts.first { $0.quote == reportFact.quote }
        XCTAssertEqual(fact?.sourceID, 1, "provenance follows the verbatim quote, not the model's id")
        XCTAssertTrue(analysis.markdown.contains("Jamie: The registration report should be delivered by email"))
    }

    func testInventedQuoteIsRejected() async {
        let invented = HostedExtraction.Fact(sourceID: 1, quote: "we will buy new cameras for every office",
                                             text: "The company will buy new cameras for every office.", importance: 3, kind: "decision")
        let provider = FakeWritingProvider(extraction: extraction(facts: [invented, reportFact]))
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        XCTAssertFalse(analysis.markdown.lowercased().contains("cameras"))
        XCTAssertFalse(analysis.facts.contains { $0.quote == invented.quote })
    }

    func testCommitmentsAreValidatedLikeOnDevice() async {
        let promise = HostedExtraction.Commitment(sourceID: 0, quote: "I'll send the deck links tomorrow so you can review the pricing changes.",
                                                  owner: "Alex", task: "Send the deck links", due: "tomorrow", confidence: 0.95, tentative: false)
        let nonSpeaker = HostedExtraction.Commitment(sourceID: 1, quote: "The registration report should be delivered by email after the audit finishes",
                                                     owner: "Zed", task: "Deliver the registration report", due: "", confidence: 0.9, tentative: false)
        let shared = HostedExtraction.Commitment(sourceID: 2, quote: "We should run a showcase for the sales team next month.",
                                                 owner: "Jamie", task: "Run a showcase for the sales team", due: "next month", confidence: 0.8, tentative: false)
        let provider = FakeWritingProvider(extraction: extraction(commitments: [promise, nonSpeaker, shared]))
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        let owners = analysis.actions.map(\.owner)
        XCTAssertTrue(owners.contains("Alex"), "\(analysis.actions)")
        XCTAssertFalse(owners.contains("Zed"))
        let showcase = analysis.actions.first { $0.task.lowercased().contains("showcase") }
        XCTAssertEqual(showcase?.owner, MeetingCommitment.unassignedOwner)
        XCTAssertEqual(showcase?.tentative, true)
        XCTAssertTrue(analysis.markdown.contains("**Alex** — Send the deck links"))
    }

    func testInventedNounOverviewIsDroppedAndRenderFallsBack() async {
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact], overview: "The team agreed to buy cameras for the warehouse."))
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        XCTAssertFalse(analysis.markdown.contains("cameras"))
        XCTAssertTrue(analysis.markdown.contains("## Overview\n\n- Jamie:"), analysis.markdown)
    }

    func testGroundedOverviewIsUsed() async {
        let overview = "The registration report should be delivered by email after the audit finishes."
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact], overview: overview))
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        XCTAssertTrue(analysis.markdown.contains("## Overview\n\n" + overview), analysis.markdown)
    }

    func testProviderFailureFallsBackToOnDeviceNotes() async {
        let provider = FakeWritingProvider(responses: [.failure(WritingModelError.unauthorized)])
        let analysis = await GroundedMeetingNotes.generate(meeting(), provider: provider)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertFalse(analysis.markdown.isEmpty)
        XCTAssertTrue(analysis.markdown.contains("## Overview"))
        let malformed = FakeWritingProvider(responses: [.success("this is not json")])
        let second = await GroundedMeetingNotes.generate(meeting(), provider: malformed)
        XCTAssertFalse(second.markdown.isEmpty)
    }

    func testListeningMeetingsDropCommitments() async {
        let promise = HostedExtraction.Commitment(sourceID: 0, quote: "I'll send the deck links tomorrow so you can review the pricing changes.",
                                                  owner: "Alex", task: "Send the deck links", due: "tomorrow", confidence: 0.95, tentative: false)
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact], commitments: [promise]))
        var listening = meeting()
        listening.kind = MeetingKind.listening.rawValue
        let analysis = await GroundedMeetingNotes.generate(listening, provider: provider)
        XCTAssertTrue(analysis.actions.isEmpty)
        XCTAssertTrue(provider.requests.first?.instructions.contains("commitments MUST be an empty list") == true)
    }

    func testCacheHitSkipsTheProvider() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-notes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var meeting = self.meeting()
        meeting.micAudioPath = dir.appendingPathComponent("rec-you.wav").path
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact], overview: "The registration report should be delivered by email after the audit finishes."))
        let first = await GroundedMeetingNotes.generate(meeting, provider: provider)
        let second = await GroundedMeetingNotes.generate(meeting, provider: provider)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(first.markdown, second.markdown)
        XCTAssertTrue(second.markdown.contains("## Overview\n\nThe registration report"))
        // A different provider id is a different cache namespace.
        let other = FakeWritingProvider(id: "fake:other", responses: [.success(String(decoding: try JSONEncoder().encode(extraction(facts: [reportFact])), as: UTF8.self))])
        _ = await GroundedMeetingNotes.generate(meeting, provider: other)
        XCTAssertEqual(other.calls, 1)
    }

    func testLongTranscriptUsesAtMostThreeRequests() async {
        var lines: [String] = []
        var seconds = 0
        while lines.joined(separator: "\n\n").count < 300_000 {
            let speaker = seconds % 60 == 0 ? "You" : "Jamie"
            lines.append("**\(speaker)** [\(seconds / 60):\(String(format: "%02d", seconds % 60))]: We talked through the registration report and the audit for section \(seconds), including the timeline for delivery by email and the people who need to review it before the quarter closes.")
            seconds += 30
        }
        let long = meeting(transcript: lines.joined(separator: "\n\n"))
        let prepared = MeetingSource.parse(long.transcript)
        let chunks = HostedMeetingNotes.chunks(prepared)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.count, 3)
        XCTAssertEqual(HostedMeetingNotes.chunks(MeetingSource.parse(transcript)).count, 1)
        let provider = FakeWritingProvider(extraction: extraction())
        _ = await GroundedMeetingNotes.generate(long, provider: provider)
        XCTAssertEqual(provider.calls, chunks.count)
    }

    @MainActor func testPrepareUsesTheProviderAndLiveDraftsDoNot() async throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let original = Database.shared
        Database.shared = db
        defer { Database.shared = original }
        var stored = meeting()
        stored.transcript = transcript + "\n\n**Jamie** [4:00]: " + String(repeating: "We also reviewed the onboarding checklist for the new analysts. ", count: 8)
        let inserted = stored
        try await db.write { try inserted.insert($0) }
        let provider = FakeWritingProvider(extraction: extraction(facts: [reportFact]))
        WritingModels.override = { purpose in purpose == .meetingNotes ? provider : nil }
        let service = MeetingNotesService(database: db)
        let notes = await service.notes(meetingID: stored.id)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertEqual(provider.calls, 1)
        let saved = try await db.read { try Meeting.fetchOne($0, key: stored.id) }
        XCTAssertEqual(saved?.summary, notes)

        let draftProvider = FakeWritingProvider(extraction: extraction(facts: [reportFact]))
        WritingModels.override = { _ in draftProvider }
        var live = meeting()
        live.transcript = stored.transcript
        service.updateDraft(live)
        for _ in 0..<600 where service.drafts[live.id] == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(draftProvider.calls, 0, "live drafts must stay on-device")
    }
}
