import XCTest
@testable import MyMan

/// Fixtures are real raw transcripts from a Wispr Flow comparison run
/// (2026-09-23). Each asserts what the rules alone must produce.
final class DictationFormattingTests: XCTestCase {
    private let terms = ["My Man", "MuckStack", "HuddleUp", "PostHog", "Amplitude", "Sentry", "Tekmetric", "Vercel", "Next.js"]
    private func rules(_ text: String) -> String { DictationCleanup.deterministicCleanup(text, terms: terms) }

    func testNumbersMoneyTimesDatesPhonesAndEmails() {
        XCTAssertEqual(rules("The meeting is on September twenty eighth at two thirty p.m. Eastern. We have fourteen open issues, three of them are P1s, and the budget is forty-five hundred dollars per month, which is about twelve percent over the last quarter. Call me at six one seven five five five O one four two or email Tommy at muckstack dot com. The site is muckstack.com slash download slash myman."),
                       "The meeting is on September 28 at 2:30 p.m. Eastern. We have 14 open issues, three of them are P1s, and the budget is $4,500 per month, which is about 12% over the last quarter. Call me at 617-555-0142 or email tommy@muckstack.com. The site is muckstack.com/download/myman.")
        XCTAssertEqual(SpokenForms.numbers("meet at four o'clock or three pm"), "meet at 4 o'clock or 3 pm")
        XCTAssertEqual(SpokenForms.numbers("nine oh five am"), "9:05 am")
        XCTAssertEqual(SpokenForms.numbers("the twentieth time"), "the 20th time")
        XCTAssertEqual(SpokenForms.numbers("one thousand two hundred people"), "1,200 people")
    }

    func testSmallAndAmbiguousNumbersStayWords() {
        for text in ["First, fix the timer sound. Second, review it.", "no one of them", "a hundred people",
                     "back in twenty twenty six", "call me at two thirty", "one two three", "I am at one"] {
            XCTAssertEqual(SpokenForms.numbers(text), text)
        }
    }

    func testSpokenPunctuationAndQuotes() {
        XCTAssertEqual(rules("Wait, comma, is that right? question mark. I thought the deadline was Friday exclamation point. Put that in quotes, open quote, ship it, close quote."),
                       "Wait, is that right? I thought the deadline was Friday! Put that in quotes \"ship it\".")
        XCTAssertEqual(rules("Thanks everyone period"), "Thanks everyone.")
        XCTAssertEqual(rules("The trial period ends Friday."), "The trial period ends Friday.")
        XCTAssertEqual(rules("Here are the three things for today. New line. First, fix the timer sound."),
                       "Here are the three things for today\nFirst, fix the timer sound.")
    }

    func testFillersStuttersAndTechnicalTerms() {
        XCTAssertEqual(rules("So um I was thinking that uh we could maybe move it. I mean it's it's not a big deal."),
                       "So I was thinking that we could maybe move it. I mean it's not a big deal.")
        XCTAssertEqual(rules("I had had enough. The ER was busy."), "I had had enough. The ER was busy.")
        XCTAssertEqual(rules("The API returns JSON with the session underscore ID field on the fix slash timers branch. We use next.js and Vercell."),
                       "The API returns JSON with the session_id field on the fix/timers branch. We use Next.js and Vercel.")
    }

    func testVocabularyRestoresProductsWithoutSwallowingCommonWords() {
        XCTAssertEqual(rules("we went through Huddle Upro map, checked post hog, amplitude, and sentry. Techmetric wants a follow up next week."),
                       "We went through HuddleUp roadmap, checked PostHog, Amplitude, and Sentry. Tekmetric wants a follow up next week.")
    }

    func testRulesAreIdempotentSoTheyCanRunAfterTheModel() {
        for text in ["The budget is $4,500 at 2:30 p.m. on September 28.", "Wait, is that right? \"ship it\".", "session_id on fix/timers"] {
            XCTAssertEqual(rules(rules(text)), rules(text))
        }
    }

    func testPolishGuardsRejectDroppedContentAndBrokenQuotes() {
        let input = "Passage five, filler words and restarts. So I was thinking that we could maybe, you know, move the release to like next week."
        XCTAssertFalse(DictationCleanup.acceptsPolish("We could maybe move the release to next week.", from: input), "Drops a clause without a correction cue")
        XCTAssertTrue(DictationCleanup.acceptsPolish("Passage five, filler words and restarts. So I was thinking that we could maybe move the release to next week.", from: input))
        let correction = "Let's meet at 3 actually no, make that at 4 o'clock, send it to Sarah. Sorry I mean send it to Jess. The total is $200. Wait - $250"
        XCTAssertTrue(DictationCleanup.acceptsPolish("Let's meet at 4 o'clock, send it to Jess. The total is $250.", from: correction))
        XCTAssertFalse(DictationCleanup.acceptsPolish("Put that in quotes \"ship it.", from: "Put that in quotes \"ship it\"."))
        XCTAssertFalse(DictationCleanup.acceptsPolish("The total is $2,500 for the team today.", from: "The total is $250 for the team today."), "No invented digits")
    }

    func testRetiredDefaultsAreRemovedOnceSoPeopleCanAddThemBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("vocabulary.md")
        try "# Vocabulary\nWhistle\nKubernetes\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DictationCleanup.userVocabulary(at: file), ["Kubernetes"])
        try "# Vocabulary\nKubernetes\nWhistle\nHuddleUp\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DictationCleanup.userVocabulary(at: file), ["Kubernetes", "Whistle", "HuddleUp"])
    }
}
