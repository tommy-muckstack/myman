import XCTest
@testable import MyMan

final class MeetingNoteGateTests: XCTestCase {
    func testTooFewWordsDoesNotWriteNotes() {
        XCTAssertFalse(MeetingNoteGate.isEnoughSpeech(words: 4, characters: 400))
    }
    func testTooFewCharactersDoesNotWriteNotes() {
        XCTAssertFalse(MeetingNoteGate.isEnoughSpeech(words: 30, characters: 159))
    }
    func testEnoughSpeechWritesNotes() {
        XCTAssertTrue(MeetingNoteGate.isEnoughSpeech(words: 5, characters: 160))
    }
    func testCharacterCountNormalizesWhitespace() {
        XCTAssertEqual(MeetingNoteGate.characterCount(of: "a   b\n\nc"), 5)
    }
}
