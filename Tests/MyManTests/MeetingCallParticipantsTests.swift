import XCTest
@testable import MyMan

final class MeetingCallParticipantsTests: XCTestCase {
    func testTileNamesAreKeptAndCallChromeIsNot() {
        let ocr = ["Michelle Shih", "Carmen DeCouto (Host)", "Alex Rivera (Me)", "Mute", "Stop Video",
                   "Share Screen", "Participants", "MCP User Research - Michelle Shih and Carmen DeCouto",
                   "1:05", "Recording", "WELCOME EVERYONE", "Jordan", "Michelle", "View", "Gallery View",
                   "renee taylor", "Renée Taylor", "https://zoom.us/j/1234"]
        let names = MeetingCallParticipants.names(in: ocr, owner: "Alex Rivera", knownNames: ["Jordan Rivera"])
        XCTAssertEqual(names, ["Michelle Shih", "Carmen DeCouto", "Jordan", "Renée Taylor"])
    }

    func testALoneFirstNameNeedsToBeExpected() {
        XCTAssertNil(MeetingCallParticipants.cleanName("Michelle"))
        XCTAssertEqual(MeetingCallParticipants.cleanName("Michelle", knownNames: ["Michelle Shih"]), "Michelle")
        XCTAssertNil(MeetingCallParticipants.cleanName("Mute"))
        XCTAssertNil(MeetingCallParticipants.cleanName("Ask Gemini"))
        XCTAssertEqual(MeetingCallParticipants.cleanName("🎤 Carmen DeCouto [Co-host]"), "Carmen DeCouto")
    }

    @MainActor func testAStrayLineMustBeSeenTwiceUnlessTheCalendarExpectsIt() {
        let scanner = CallParticipantScanner()
        XCTAssertEqual(scanner.confirmed(knownNames: []), [])
    }
}
