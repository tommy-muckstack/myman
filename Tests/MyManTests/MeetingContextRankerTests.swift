import XCTest
import GRDB
@testable import MyMan

final class MeetingContextRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var liveStart: Date { now.addingTimeInterval(-600) }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        try queue.write { db in
            let threeWeeks = now.addingTimeInterval(-21 * 86_400)
            let participants = #"[{"name":"Tommy","email":"tommy@example.com","isOwner":true},{"name":"Amy Chen","email":"amy@example.com","isOwner":false}]"#
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript,summary,participantsJSON) VALUES(?,?,?,?,?,?)",
                           arguments: ["past", "Roadmap sync", threeWeeks, "**Amy Chen** [0:00]: We agreed the roadmap waits for the budget.", "Roadmap waits for budget.", participants])
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript,summary,participantsJSON) VALUES(?,?,?,?,?,?)",
                           arguments: ["live", "Pricing review", liveStart, "**Tommy** [0:00]: pricing pricing", "", participants])
            try db.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript,summary,participantsJSON) VALUES(?,?,?,?,?,?)",
                           arguments: ["later", "Future pricing", now.addingTimeInterval(3600), "pricing", "", participants])
            try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)",
                           arguments: ["keyword", "Pricing ideas", "Tiered pricing for the Houston market.", now.addingTimeInterval(-86_400 * 5), now.addingTimeInterval(-86_400 * 5)])
            try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt,meetingID) VALUES(?,?,?,?,?,?)",
                           arguments: ["linked", "Live note", "pricing pricing pricing", liveStart, liveStart, "live"])
            try db.execute(sql: "INSERT INTO brainNote(id,path,title,body,createdAt,updatedAt,mtime,size) VALUES(?,?,?,?,?,?,?,?)",
                           arguments: ["b1", "/tmp/brain/muckstack/pricing.md", "Pricing model", "Notes on pricing tiers and Houston.", now.addingTimeInterval(-86_400 * 2), now.addingTimeInterval(-86_400 * 2), 1.0, 40])
            try db.execute(sql: "INSERT INTO note(id,title,body,createdAt,updatedAt) VALUES(?,?,?,?,?)",
                           arguments: ["hidden", "Hidden pricing", "pricing", now.addingTimeInterval(-86_400), now.addingTimeInterval(-86_400)])
            try db.execute(sql: "UPDATE captureItem SET excluded = 1 WHERE id = 'note-hidden'")
        }
        return queue
    }

    private func request(terms: [String], attendees: [MeetingContextPerson] = [MeetingContextPerson(name: "Amy Chen", email: "amy@example.com")],
                         seed: Bool = false, excluded: Set<String> = []) -> MeetingContextRequest {
        MeetingContextRequest(meetingID: "live", startedAt: liveStart, title: "Pricing review", attendees: attendees,
                              terms: terms, seed: seed, excludedIDs: excluded, now: now)
    }

    func testPeopleOverlapOutranksKeywordOnly() throws {
        let cards = try MeetingContextRanker.cards(for: request(terms: ["pricing"]), database: database())
        XCTAssertEqual(cards.first?.id, "meeting-past", "the meeting Amy was in should lead: \(cards.map(\.id))")
        XCTAssertEqual(cards.first?.basis, .people)
        XCTAssertTrue(cards.first?.reason.hasPrefix("Last met") == true)
        XCTAssertTrue(cards.first?.reason.contains("Amy") == true)
    }

    func testLiveMeetingLinkedNoteExcludedAndFutureItemsAreAbsent() throws {
        let ids = Set(try MeetingContextRanker.cards(for: request(terms: ["pricing"]), database: database()).map(\.id))
        XCTAssertFalse(ids.contains("meeting-live"))
        XCTAssertFalse(ids.contains("note-linked"))
        XCTAssertFalse(ids.contains("note-hidden"))
        XCTAssertFalse(ids.contains("meeting-later"))
        XCTAssertTrue(ids.contains("note-keyword"))
    }

    func testBrainzNoteBecomesATopicCard() throws {
        let cards = try MeetingContextRanker.cards(for: request(terms: ["pricing", "Houston"]), database: database())
        let brain = cards.first { $0.id == "brain-b1" }
        XCTAssertNotNil(brain, "Brainz note should be a card: \(cards.map(\.id))")
        XCTAssertEqual(brain?.basis, .topic)
        XCTAssertTrue(brain?.reason.hasPrefix("Mentions:") == true)
        XCTAssertEqual(brain?.item.kind, "brainNote")
    }

    func testAlreadyShownCardsAreNotRepeated() throws {
        let ids = Set(try MeetingContextRanker.cards(for: request(terms: ["pricing"], excluded: ["note-keyword", "meeting-past"]), database: database()).map(\.id))
        XCTAssertFalse(ids.contains("note-keyword"))
        XCTAssertFalse(ids.contains("meeting-past"))
    }

    func testPastMeetingsMatchByEmailOrNameAndIgnoreOwner() throws {
        let db = try database()
        let byEmail = try MeetingContextRanker.pastMeetings(with: [MeetingContextPerson(name: "A. Chen", email: "AMY@example.com")],
                                                            excluding: "live", before: liveStart, database: db)
        XCTAssertEqual(byEmail.map(\.item.id), ["meeting-past"])
        let byName = try MeetingContextRanker.pastMeetings(with: [MeetingContextPerson(name: "Amy", email: nil)],
                                                           excluding: "live", before: liveStart, database: db)
        XCTAssertEqual(byName.map(\.item.id), ["meeting-past"])
        let owner = try MeetingContextRanker.pastMeetings(with: [MeetingContextPerson(name: "Tommy", email: "tommy@example.com")],
                                                          excluding: "live", before: liveStart, database: db)
        XCTAssertTrue(owner.isEmpty)
    }

    func testNoTermsAndNoPeopleYieldsNothing() throws {
        let cards = try MeetingContextRanker.cards(for: request(terms: [], attendees: []), database: database())
        XCTAssertTrue(cards.isEmpty)
    }
}
