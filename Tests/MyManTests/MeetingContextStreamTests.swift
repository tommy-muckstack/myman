import XCTest
import GRDB
@testable import MyMan

@MainActor
final class MeetingContextStreamTests: XCTestCase {
    /// Records every request and answers with one card per request.
    private final class FakeProvider: MeetingContextProvider, @unchecked Sendable {
        let lock = NSLock()
        private(set) var requests: [MeetingContextRequest] = []
        var cardsPerRequest = 1
        func terms(in text: String, exclude: Set<String>, limit: Int) -> [String] {
            Array(CaptureText.words(text).filter { $0.count >= 4 }.prefix(limit))
        }
        func rank(_ request: MeetingContextRequest, database: DatabaseQueue) throws -> [MeetingContextCard] {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let index = requests.count
            return (0..<cardsPerRequest).map { offset in
                let id = "fake-\(index)-\(offset)"
                let item = CaptureItem(id: id, kind: "note", sourceID: id, rawTitle: "Card \(id)", generatedTitle: "", userTitle: "",
                                       body: "", summary: "", metadata: "", sourcePath: "", capturedAt: request.now, modifiedAt: request.now,
                                       pinned: false, excluded: false, revision: 1)
                return MeetingContextCard(id: id, item: item, basis: .topic, reason: "Mentions: test", people: [], excerpt: "", score: 1)
            }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    }

    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var provider = FakeProvider()
    private var database: DatabaseQueue!
    private var stream: MeetingContextStream!

    override func setUp() async throws {
        provider = FakeProvider()
        database = try DatabaseQueue()
        try Database.migrator.migrate(database)
        stream = MeetingContextStream(provider: provider, now: { [unowned self] in self.clock })
    }

    private func session() -> MeetingContextStream.Session {
        MeetingContextStream.Session(meetingID: "live", startedAt: clock, title: "Pricing review with Acme",
                                     attendees: [MeetingContextPerson(name: "Amy Chen", email: nil)], ownerName: "Tommy")
    }

    private func rows(words: Int) -> [LiveMeetingTranscript.Row] {
        let text = (0..<words).map { "topic\($0 % 7)word" }.joined(separator: " ")
        return [LiveMeetingTranscript.Row(id: "r1", speaker: "Amy Chen", timestamp: "0:00", text: text)]
    }

    private func settle() async {
        for _ in 0..<50 where stream.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testStartSeedsOnce() async {
        stream.start(session: session(), database: database)
        await settle()
        XCTAssertEqual(provider.count, 1)
        XCTAssertEqual(provider.requests.first?.seed, true)
        XCTAssertTrue(provider.requests.first?.terms.contains("Acme") == true, "title proper noun should seed: \(provider.requests.first?.terms ?? [])")
        XCTAssertEqual(stream.cards.count, 1)
    }

    func testFewWordsDoNotRefresh() async {
        stream.start(session: session(), database: database)
        await settle()
        clock.addTimeInterval(120)
        stream.update(rows: rows(words: 20))
        await settle()
        XCTAssertEqual(provider.count, 1)
    }

    func testEnoughWordsButTooSoonWaitsThenRefreshes() async {
        stream.start(session: session(), database: database)
        await settle()
        clock.addTimeInterval(5)
        stream.update(rows: rows(words: 60))
        await settle()
        XCTAssertEqual(provider.count, 1, "the interval has not passed, so no refresh yet")
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 61))
        await settle()
        XCTAssertEqual(provider.count, 2)
        XCTAssertEqual(provider.requests.last?.seed, false)
        XCTAssertFalse(provider.requests.last?.terms.isEmpty ?? true)
    }

    func testShrinkingRowsNeverProduceANegativeDelta() async {
        stream.start(session: session(), database: database)
        await settle()
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 100))
        await settle()
        XCTAssertEqual(provider.count, 2)
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 70))
        await settle()
        XCTAssertEqual(provider.count, 2, "fewer words than at the last refresh is not new speech")
    }

    func testDismissedAndShownCardsAreExcludedFromLaterRequests() async {
        stream.start(session: session(), database: database)
        await settle()
        let first = stream.cards[0]
        stream.dismiss(first)
        XCTAssertTrue(stream.cards.isEmpty)
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 80))
        await settle()
        XCTAssertTrue(provider.requests.last?.excludedIDs.contains(first.id) == true)
    }

    func testHideForMeetingStopsRefreshing() async {
        stream.start(session: session(), database: database)
        await settle()
        stream.hideForMeeting()
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 80))
        await settle()
        XCTAssertEqual(provider.count, 1)
        XCTAssertTrue(stream.hiddenForMeeting)
    }

    func testStopClearsEverything() async {
        stream.start(session: session(), database: database)
        await settle()
        stream.stop()
        XCTAssertTrue(stream.cards.isEmpty)
        XCTAssertFalse(stream.isActive)
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 80))
        await settle()
        XCTAssertEqual(provider.count, 1)
    }

    func testDisabledStreamNeverQueries() async {
        stream.enabled = false
        stream.start(session: session(), database: database)
        await settle()
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 80))
        await settle()
        XCTAssertEqual(provider.count, 0)
    }

    func testCardsAreCappedNewestFirst() async {
        provider.cardsPerRequest = 10
        stream.start(session: session(), database: database)
        await settle()
        clock.addTimeInterval(60)
        stream.update(rows: rows(words: 80))
        await settle()
        XCTAssertEqual(stream.cards.count, MeetingContextStream.maxCards)
        XCTAssertTrue(stream.cards.first?.id.hasPrefix("fake-2-") == true)
    }
}
