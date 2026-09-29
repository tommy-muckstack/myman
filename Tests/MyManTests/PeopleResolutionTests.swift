import XCTest
import GRDB
@testable import MyMan

final class PeopleResolutionTests: XCTestCase {
    struct Fixture: Decodable {
        var name: String
        var records: [PeopleResolution.Record]
        var names: [String]
        var limit: Int
        var expected: [PeopleResolution.Match]
    }
    func testSharedResolutionFixtures() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/people-resolution.json")
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file)) {
            XCTAssertEqual(try PeopleResolution.resolve(names: fixture.names, records: fixture.records, limit: fixture.limit), fixture.expected, fixture.name)
            XCTAssertEqual(try PeopleResolution.resolve(names: fixture.names, records: fixture.records.reversed(), limit: fixture.limit), fixture.expected, fixture.name + " reversed")
        }
    }
    func testBoundsAndNoPartialResolution() throws {
        for names in [[], [" "], ["???"], ["Sam\nInvite"], [String(repeating: "a", count: 201)], Array(repeating: "Sam", count: 21)] {
            XCTAssertThrowsError(try PeopleResolution.resolve(names: names, records: []))
        }
        for limit in [0, 11] { XCTAssertThrowsError(try PeopleResolution.resolve(names: ["Sam"], records: [], limit: limit)) }
        XCTAssertThrowsError(try PeopleResolution.resolve(names: ["Sam"], records: Array(repeating: .init(name: "Sam", email: nil, source: "people"), count: 10_001)))
    }
    private func fixtureDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE person(id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT, meetCount INTEGER,
                  firstMetAt DATETIME, lastMetAt DATETIME, hidden BOOLEAN);
                CREATE TABLE meeting(id TEXT PRIMARY KEY, participantsJSON TEXT);
                CREATE TABLE captureItem(sourceID TEXT, kind TEXT, excluded BOOLEAN);
                """)
        }
        return database
    }
    func testSavedPeopleAndParticipantsHonorHiddenPeopleExcludedMeetingsAndOwners() throws {
        let database = try fixtureDatabase()
        try database.write { db in
            for person in [Person(id: "p", name: "Jilles Smith", email: "jilles@example.test", meetCount: 1, firstMetAt: .now, lastMetAt: .now),
                           Person(id: "h", name: "Hidden Person", email: "hidden@example.test", meetCount: 1, firstMetAt: .now, lastMetAt: .now, hidden: true)] { try person.insert(db) }
            let participants = [MeetingParticipant(name: "Harshil Patel", email: "harshil@example.test"),
                                MeetingParticipant(name: "Hidden Person", email: "different@example.test"),
                                MeetingParticipant(name: "Alias", email: "hidden@example.test"),
                                MeetingParticipant(name: "My Owner", email: "owner@example.test", isOwner: true)]
            let json = String(decoding: try JSONEncoder().encode(participants), as: UTF8.self)
            try db.execute(sql: "INSERT INTO meeting VALUES ('m', ?); INSERT INTO captureItem VALUES ('m','meeting',0)", arguments: [json])
            try db.execute(sql: "INSERT INTO meeting VALUES ('excluded', ?); INSERT INTO captureItem VALUES ('excluded','meeting',1)", arguments: [#"[{"name":"Excluded","email":"excluded@example.test","isOwner":false}]"#])
        }
        let before = try database.read { $0.totalChangesCount }
        let records = try People.resolutionRecords(database: database)
        let result = try PeopleResolution.resolve(names: ["Jilles", "Harshil", "Hidden", "Alias", "My Owner", "Excluded"], records: records)
        XCTAssertEqual(result.map(\.status), ["resolved", "resolved", "not_found", "not_found", "not_found", "not_found"])
        XCTAssertEqual(result[1].candidates[0].sources, ["meeting_participants"])
        XCTAssertEqual(try database.read { $0.totalChangesCount }, before)
    }
    func testMalformedMeetingMetadataFailsInsteadOfResolvingFromAnIncompleteSource() throws {
        let database = try fixtureDatabase()
        try database.write { try $0.execute(sql: "INSERT INTO meeting VALUES ('m','broken'); INSERT INTO captureItem VALUES ('m','meeting',0)") }
        XCTAssertThrowsError(try People.resolutionRecords(database: database)) { XCTAssertEqual(($0 as? AgentError)?.code, "PEOPLE_SOURCE_INVALID") }
    }
    @MainActor func testGrantIsIndependentDefaultOffAndCannotBeChangedThroughSettingsAction() throws {
        let suite = "PeopleResolveTests-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentConsent.status(defaults)["people_read"], false)
        defaults.set(true, forKey: "agentLibraryEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("people.resolve", args: [:], defaults: defaults))
        defaults.set(true, forKey: "agentPeopleReadEnabled") // Synthetic defaults only.
        XCTAssertNoThrow(try AgentConsent.validate("people.resolve", args: [:], defaults: defaults))
        defaults.set(false, forKey: "agentActionsEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("people.resolve", args: [:], defaults: defaults))
        let actions = AgentActions.catalog["actions"] as! [[String: Any]]
        let schema = actions.first { $0["name"] as? String == "settings.update" }!["inputSchema"] as! [String: Any]
        XCTAssertThrowsError(try AgentSchema.validate(["agentPeopleReadEnabled": true], schema: schema))
        XCTAssertEqual(AgentConsent.requirements("people.resolve"), ["people_read"])
    }
}
