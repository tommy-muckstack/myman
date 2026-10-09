import XCTest
@testable import MyMan

final class TaskExtractorHostedTests: XCTestCase {
    private let note = """
    Planning notes for the week. TODO: send the deck to Priya before Thursday. \
    We also talked about pricing. Don't forget to book the dentist appointment. \
    Remind me to renew the domain registration next month.
    """

    func testVerbatimQuoteIsAccepted() {
        let content = "- Send the deck to Priya | send the deck to Priya before Thursday"
        XCTAssertEqual(TaskExtractor.titles(from: content, text: note, source: .note), ["Send the deck to Priya"])
    }

    func testMissingOrShortOrFabricatedQuoteIsRejected() {
        XCTAssertEqual(TaskExtractor.titles(from: "- Send the deck", text: note, source: .note), [])
        XCTAssertEqual(TaskExtractor.titles(from: "- Send the deck | deck", text: note, source: .note), [])
        XCTAssertEqual(TaskExtractor.titles(from: "- Buy a new laptop | buy a new laptop this week", text: note, source: .note), [])
    }

    func testQuoteMatchingIgnoresCaseAndQuotes() {
        let content = "- Book the dentist appointment | “BOOK THE DENTIST APPOINTMENT”"
        XCTAssertEqual(TaskExtractor.titles(from: content, text: note, source: .note), ["Book the dentist appointment"])
    }

    func testHonorsMaxTasksPerSource() {
        let content = """
        - Send the deck to Priya | send the deck to Priya before Thursday
        - Book the dentist appointment | book the dentist appointment
        - Renew the domain registration | renew the domain registration next month
        """
        XCTAssertEqual(TaskExtractor.titles(from: content, text: note, source: .dictation).count, 1)
        XCTAssertEqual(TaskExtractor.titles(from: content, text: note, source: .note).count, 3)
    }

    func testNoneAndProseYieldNothing() {
        XCTAssertEqual(TaskExtractor.titles(from: "NONE", text: note, source: .note), [])
        XCTAssertEqual(TaskExtractor.titles(from: "There are no tasks here.", text: note, source: .note), [])
        XCTAssertEqual(TaskExtractor.titles(from: "NONE\n- Send the deck to Priya | send the deck to Priya before Thursday", text: note, source: .note), ["Send the deck to Priya"])
    }

    func testInstructionsCarryTheSourceBar() {
        XCTAssertTrue(TaskExtractor.instructions(for: .dictation).contains("remind me to"))
        XCTAssertTrue(TaskExtractor.instructions(for: .note).contains("at most 3 tasks"))
        XCTAssertTrue(TaskExtractor.instructions(for: .note).contains("NONE"))
    }
}
