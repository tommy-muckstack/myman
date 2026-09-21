import XCTest
@testable import MyMan

final class MeetingScreenshotCueTests: XCTestCase {
    func testContextualVisualReferencesAndNonVisualConversation() {
        for text in ["Notice how this chart changes on the right.", "Compare these columns.",
                     "On this slide we have last quarter's results.", "Let me show you the new onboarding flow."] {
            XCTAssertTrue(MeetingScreenshotCueTracker.isVisualReference(text, hasScreenContext: false), text)
        }
        for text in ["Look at this.", "See here.", "Watch what happens when I click here.", "Over on the left hand side."] {
            XCTAssertTrue(MeetingScreenshotCueTracker.isVisualReference(text, hasScreenContext: true), text)
            XCTAssertFalse(MeetingScreenshotCueTracker.isVisualReference(text, hasScreenContext: false), text)
        }
        for text in ["See you tomorrow.", "I see what you mean.", "We used to say look at this chart.",
                     "He said look at this slide.", "I'll show you later.", "I can't see this chart.",
                     "Outlook sent this chart by email.", "Don't look at this screen."] {
            XCTAssertFalse(MeetingScreenshotCueTracker.isVisualReference(text, hasScreenContext: true), text)
        }
    }

    func testRollingContextCooldownAndCatchupTranscription() {
        var tracker = MeetingScreenshotCueTracker()
        var turns = [MeetingTurn(start: 1, end: 3, speaker: "Peer", text: "I'm sharing my screen.")]
        XCTAssertTrue(tracker.shouldCapture(turns: turns, elapsed: 5))
        XCTAssertFalse(tracker.shouldCapture(turns: turns, elapsed: 6), "Same transcript must not retrigger")
        turns.append(MeetingTurn(start: 8, end: 10, speaker: "Peer", text: "Look at this."))
        XCTAssertFalse(tracker.shouldCapture(turns: turns, elapsed: 12), "Rapid related references form one capture")
        turns.append(MeetingTurn(start: 30, end: 32, speaker: "Peer", text: "See here."))
        XCTAssertTrue(tracker.shouldCapture(turns: turns, elapsed: 35))
        turns.append(MeetingTurn(start: 50, end: 51, speaker: "Peer", text: "I stopped sharing."))
        turns.append(MeetingTurn(start: 60, end: 61, speaker: "Owner", text: "Look at this."))
        XCTAssertFalse(tracker.shouldCapture(turns: turns, elapsed: 65))
        var catchup = MeetingScreenshotCueTracker()
        XCTAssertFalse(catchup.shouldCapture(turns: turns, elapsed: 600), "Old references must not capture the current screen")
        var story = MeetingScreenshotCueTracker()
        let reported = [MeetingTurn(start: 1, end: 3, speaker: "Peer", text: "He said look at this chart."),
                        MeetingTurn(start: 5, end: 6, speaker: "Peer", text: "Look at this.")]
        XCTAssertFalse(story.shouldCapture(turns: reported, elapsed: 8), "Stories must not establish current screen context")
    }
}
