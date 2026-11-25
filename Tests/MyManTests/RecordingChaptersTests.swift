import XCTest
@testable import MyMan

final class RecordingChaptersTests: XCTestCase {
    private func seg(_ start: Double, _ end: Double, _ text: String) -> RecordingTranscript.Segment {
        RecordingTranscript.Segment(start: start, end: end, text: text)
    }

    func testNoTranscriptNoChapters() {
        XCTAssertEqual(RecordingChapters.make(from: []), [])
    }

    func testContinuousSpeechIsOneChapter() {
        let segments = [seg(0, 5, "Welcome to the walkthrough"), seg(5.5, 30, "next we open settings")]
        let chapters = RecordingChapters.make(from: segments)
        XCTAssertEqual(chapters, [RecordingChapters.Chapter(startMs: 0, title: "Welcome to the walkthrough")])
    }

    func testLongPauseStartsANewChapter() {
        let segments = [seg(0, 10, "Intro to the report"), seg(40, 60, "Now the numbers for March")]
        let chapters = RecordingChapters.make(from: segments)
        XCTAssertEqual(chapters.map(\.startMs), [0, 40_000])
        XCTAssertEqual(chapters[1].title, "Now the numbers for March")
    }

    func testShortPauseDoesNotSplit() {
        let segments = [seg(0, 10, "one"), seg(12, 30, "two")]
        XCTAssertEqual(RecordingChapters.make(from: segments).count, 1)
    }

    func testBoundariesAreNotCloserThanTheMinimumLength() {
        // Pauses of 5 s at 30 s and 40 s, and 15 s at 60 s. The 40 s pause is too close to the 30 s one, so it is dropped.
        let segments = [seg(0, 25, "a"), seg(30, 35, "b"), seg(40, 45, "c"), seg(60, 70, "d")]
        XCTAssertEqual(RecordingChapters.make(from: segments).map(\.startMs), [0, 30_000, 60_000])
    }

    func testAPauseBeforeTheFirstMinimumLengthIsIgnored() {
        // A pause at 10 s is too early to start a chapter.
        let segments = [seg(0, 5, "a"), seg(10, 15, "b")]
        XCTAssertEqual(RecordingChapters.make(from: segments).map(\.startMs), [0])
    }

    func testAtMostEightChapters() {
        let segments = (0..<20).map { i in seg(Double(i) * 60, Double(i) * 60 + 30, "section \(i)") }
        XCTAssertLessThanOrEqual(RecordingChapters.make(from: segments).count, RecordingChapters.maximumChapters)
    }

    func testBlankOpeningGetsANumberedTitle() {
        XCTAssertEqual(RecordingChapters.title(for: "  ", index: 2), "Part 3")
    }
}
