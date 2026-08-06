import XCTest
@testable import MyMan

final class CoreTests: XCTestCase {
    func testCosineSimilarityIdenticalVectorsIsOne() {
        XCTAssertEqual(SearchService.cosine([1, 2, 3], [1, 2, 3]), 1, accuracy: 0.0001)
    }

    func testCosineSimilarityRejectsMismatchedVectors() {
        XCTAssertEqual(SearchService.cosine([1, 2], [1]), 0)
    }

    func testMeetingBrainPathIsStableAndScopedToMeetings() {
        let path = Brain.meetingFilePath(id: "12345678-0000-0000-0000-000000000000",
                                         startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(path.hasSuffix("meetings/1969-12-31-12345678.md")
                    || path.hasSuffix("meetings/1970-01-01-12345678.md"))
    }

    func testDictationRestoresKnownASRAliases() {
        let restored = DictationCleanup.canonicalizeKnownTerms(
            "Compare WhisperFlow, event kit, Avantik, and Muck Stack in MyMan."
        )
        XCTAssertEqual(restored, "Compare Wispr Flow, EventKit, EventKit, and MuckStack in My Man.")
    }

    func testOnlyMyManAndMuckStackAreBundledVocabulary() {
        XCTAssertEqual(DictationCleanup.builtInVocabulary, ["My Man", "MuckStack"])
    }

    func testDictationKeepsVersionNumbersAndRemovesStrandedQuote() {
        XCTAssertEqual(
            DictationCleanup.normalizeDictationFormatting("Ship 1 . 1 . 29 for MuckStack\"."),
            "Ship 1.1.29 for MuckStack."
        )
    }
}
