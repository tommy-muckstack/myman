import AppKit
import SwiftUI
import XCTest
@testable import MyMan

private actor DelayedLiveReader: LiveMeetingTranscriptReading {
    let started = XCTestExpectation(description: "Live reader started")
    private var continuation: CheckedContinuation<[MeetingTurn], Never>?
    func prepare() async throws { }
    func next() async throws -> [MeetingTurn] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish(_ turns: [MeetingTurn]) { continuation?.resume(returning: turns); continuation = nil }
}

private actor RetryingLiveReader: LiveMeetingTranscriptReading {
    private var calls = 0
    func prepare() async throws { }
    func next() async throws -> [MeetingTurn] {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadUnknown) }
        if calls == 2 { return [MeetingTurn(start: 10, end: 15, speaker: "Speaker 2", text: "Next passage.")] }
        return []
    }
}

final class LiveMeetingTranscriptTests: XCTestCase {
    @MainActor func testRetryKeepsHumanEditsAndSpeakerIdentity() async throws {
        let transcript = LiveMeetingTranscript()
        transcript.start(reader: RetryingLiveReader(), ownerName: "Alex", candidates: .none)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while transcript.status != .unavailable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transcript.status, .unavailable)
        transcript.append([MeetingTurn(start: 0, end: 5, speaker: "Speaker 2", text: "Original words.")],
                          ownerName: "Alex", candidates: .none)
        let id = try XCTUnwrap(transcript.rows.first?.id)
        transcript.edit(rowID: id, text: "Corrected words.", speakerName: "Jamie")
        transcript.retry()
        let retryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while transcript.rows.count < 2, ContinuousClock.now < retryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transcript.rows.map(\.speaker), ["Jamie", "Jamie"])
        XCTAssertEqual(transcript.rows.first?.text, "Corrected words.")
        XCTAssertEqual(transcript.corrections.count, 2)
        transcript.stop()
    }
    func testIncrementalReadWorksBeforeWavHeaderIsFinalized() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url))
        writer.append(Array(repeating: 0.25, count: 3 * 16000))
        XCTAssertNil(try LiveMeetingTranscriptReader.readChunk(at: url, offset: 0))
        writer.append(Array(repeating: 0.25, count: 2 * 16000))
        let first = try XCTUnwrap(LiveMeetingTranscriptReader.readChunk(at: url, offset: 0))
        XCTAssertEqual(first.samples.count, 5 * 16000)
        XCTAssertEqual(first.samples[0], 0.25, accuracy: 0.0001)
        XCTAssertNil(try LiveMeetingTranscriptReader.readChunk(at: url, offset: first.samples.count))
        writer.append(Array(repeating: 0.5, count: 20 * 16000))
        let second = try XCTUnwrap(LiveMeetingTranscriptReader.readChunk(at: url, offset: first.samples.count))
        XCTAssertEqual(second.offset, 5 * 16000)
        XCTAssertLessThanOrEqual(second.samples.count, 12 * 16000)
        XCTAssertGreaterThanOrEqual(second.samples.count, 8 * 16000)
        XCTAssertEqual(second.samples[0], 0.5, accuracy: 0.0001)
        _ = writer.close()
    }

    func testOverlappingVoicesRemainUncertainAndStableLabelsSurviveWindows() {
        let voices = [MeetingTurn(start: 0, end: 5, speaker: "Speaker 4", text: ""),
                      MeetingTurn(start: 3, end: 8, speaker: "Speaker 2", text: "")]
        let turns = LiveMeetingTranscriptReader.intervals(voices: voices, duration: 10)
        XCTAssertEqual(turns.map(\.speaker), ["Speaker 4", "Speaker unclear", "Speaker 2", "Speaker unclear"])
        XCTAssertEqual(turns.map(\.start), [0, 3, 5, 8])
        XCTAssertEqual(turns.map(\.end), [3, 5, 8, 10])
    }

    @MainActor func testSpeakerNamesTimestampsAndChronologicalHistory() {
        let transcript = LiveMeetingTranscript()
        transcript.append([
            MeetingTurn(start: 65, end: 70, speaker: "Speaker 2", text: "We can send the plan tomorrow."),
            MeetingTurn(start: 5, end: 10, speaker: "You", text: "Let’s review the proposal.")
        ], ownerName: "Alex", candidates: SpeakerCandidates(names: ["Jamie"], fromAttendees: true))
        XCTAssertEqual(transcript.rows.map(\.speaker), ["Alex (you)", "Jamie"])
        XCTAssertEqual(transcript.rows.map(\.timestamp), ["0:05", "1:05"])
        let originalID = transcript.rows[0].id
        transcript.append([MeetingTurn(start: 80, end: 85, speaker: "Speaker unclear", text: "I'm Jamie, and I'm Sam.")],
                          ownerName: "Alex", candidates: SpeakerCandidates(names: ["Jamie", "Sam"], fromAttendees: true))
        XCTAssertEqual(transcript.rows[0].id, originalID)
        XCTAssertEqual(transcript.rows.last?.speaker, "Speaker unclear")
        transcript.stop()
        XCTAssertTrue(transcript.rows.isEmpty)
    }

    @MainActor func testLateLiveResultsCannotReturnAfterStop() async {
        let reader = DelayedLiveReader()
        let transcript = LiveMeetingTranscript()
        transcript.start(reader: reader, ownerName: "Alex", candidates: .none)
        await fulfillment(of: [reader.started], timeout: 2)
        transcript.stop()
        await reader.finish([MeetingTurn(start: 0, end: 4, speaker: "You", text: "A cancelled take")])
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(transcript.rows.isEmpty)
        XCTAssertEqual(transcript.status, .waiting)
    }

    @MainActor func testNativeTranscriptPreservesScrollPositionAndSelection() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let transcript = LiveMeetingTranscript()
        let turns: [MeetingTurn] = (0..<40).map { index in
            let start = Double(index * 10)
            return MeetingTurn(start: start, end: start + 5, speaker: index % 2 == 0 ? "You" : "Speaker 2",
                               text: "We should review the proposal and send a follow-up after this meeting.")
        }
        transcript.append(turns, ownerName: "Alex", candidates: SpeakerCandidates(names: ["Jamie"], fromAttendees: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: MeetingLiveTranscriptView(transcript: transcript, retry: {}))
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(host))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertGreaterThan(text.bounds.height, scroll.contentSize.height)
        XCTAssertTrue(text.string.contains("Alex (you)"))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        text.setSelectedRange(NSRange(location: 2, length: 6))
        var rows = transcript.rows
        rows.append(.init(id: "new", speaker: "Jamie", timestamp: "8:00", text: "One more detail."))
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 100, accuracy: 1)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 2, length: 6))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: text.bounds.height - scroll.contentSize.height))
        rows.append(.init(id: "newer", speaker: "Alex", timestamp: "8:10", text: "We can make that change tomorrow."))
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows)
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.height, accuracy: 2)
    }
}
