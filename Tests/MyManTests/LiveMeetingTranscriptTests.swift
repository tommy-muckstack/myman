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
    @MainActor func testScreenshotTimestampSeeksToMatchingTranscriptAndPreservesReadingPosition() throws {
        let rows: [LiveMeetingTranscript.Row] = (0..<20).map { index in
            let start = Double(index * 10)
            return LiveMeetingTranscript.Row(id: "row-\(index)", speaker: "Speaker \(index % 2)",
                timestamp: MeetingSource.stamp(start), text: "Discussion of the chart at \(index).", start: start)
        }
        XCTAssertEqual(LiveTranscriptScrollView.rowForTimestamp(145, rows: rows)?.id, "row-14")
        XCTAssertEqual(LiveTranscriptScrollView.rowForTimestamp(0, rows: rows)?.id, "row-0")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows, follow: false)
        LiveTranscriptScrollView.seek(to: 145, rows: rows, text: text, scroll: scroll)
        let selected = (text.string as NSString).substring(with: text.selectedRange())
        XCTAssertTrue(selected.contains("2:20"))
        XCTAssertTrue(selected.contains("chart at 14"))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        let position = scroll.contentView.bounds.origin
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows + [.init(id: "new", speaker: "Peer", timestamp: "4:00", text: "More words", start: 240)], follow: false)
        XCTAssertEqual(scroll.contentView.bounds.origin, position)
    }

    @MainActor func testRetryKeepsHumanEditsAndSpeakerIdentity() async throws {
        let transcript = LiveMeetingTranscript(automaticRetryDelays: [])
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

    @MainActor func testOneSpeakerTalkingThroughPausesIsOneBlock() {
        let transcript = LiveMeetingTranscript()
        let jamie = SpeakerCandidates(names: ["Jamie"], fromAttendees: true)
        transcript.append([
            MeetingTurn(start: 0, end: 4, speaker: "You", text: "We also call Amplitude C P."),
            MeetingTurn(start: 9, end: 14, speaker: "You", text: "our internal"),
            MeetingTurn(start: 30, end: 34, speaker: "You", text: "Jupiter container."),
            MeetingTurn(start: 36, end: 40, speaker: "Speaker 2", text: "I like it."),
            MeetingTurn(start: 44, end: 47, speaker: "You", text: "Great."),
        ], ownerName: "Alex", candidates: jamie)
        XCTAssertEqual(transcript.rows.map(\.speaker), ["Alex (you)", "Jamie", "Alex (you)"])
        XCTAssertEqual(transcript.rows.map(\.timestamp), ["0:00", "0:36", "0:44"])
        XCTAssertEqual(transcript.rows[0].text, "We also call Amplitude C P. our internal Jupiter container.")
        XCTAssertEqual(transcript.rows[0].turnIDs.count, 3)
        // Later words from the same person join the open block, and the
        // block's identity never changes under the reader.
        let firstID = transcript.rows[2].id
        transcript.append([MeetingTurn(start: 50, end: 53, speaker: "You", text: "Let's move on.")], ownerName: "Alex", candidates: jamie)
        XCTAssertEqual(transcript.rows.count, 3)
        XCTAssertEqual(transcript.rows[2].id, firstID)
        XCTAssertEqual(transcript.rows[2].text, "Great. Let's move on.")
        // Uncertain audio is never folded into a person's block.
        transcript.append([MeetingTurn(start: 55, end: 57, speaker: "Speaker unclear", text: "Yeah."),
                           MeetingTurn(start: 58, end: 60, speaker: "Speaker unclear", text: "Sure.")], ownerName: "Alex", candidates: jamie)
        XCTAssertEqual(transcript.rows.map(\.speaker).suffix(2), ["Speaker unclear", "Speaker unclear"])
    }

    @MainActor func testEditingABlockOwnsItsWholeInterval() {
        let transcript = LiveMeetingTranscript()
        var edits: [LiveTranscriptCorrection] = []
        transcript.onEditsChanged = { edits = $0 }
        transcript.append([
            MeetingTurn(start: 0, end: 4, speaker: "Speaker 2", text: "We can send the plan"),
            MeetingTurn(start: 5, end: 9, speaker: "Speaker 2", text: "tomorrow."),
            MeetingTurn(start: 12, end: 15, speaker: "You", text: "Thanks."),
        ], ownerName: "Alex", candidates: .none)
        XCTAssertEqual(transcript.rows.count, 2)
        let block = transcript.rows[0]
        transcript.edit(rowID: block.id, text: "We can send the plan on Tuesday.", speakerName: "Jamie")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].start, 0); XCTAssertEqual(edits[0].end, 9)
        XCTAssertEqual(edits[0].text, "We can send the plan on Tuesday.")
        XCTAssertEqual(edits[0].speakerName, "Jamie")
        XCTAssertEqual(transcript.rows.map(\.speaker), ["Jamie", "Alex (you)"])
        XCTAssertEqual(transcript.rows[0].text, "We can send the plan on Tuesday.")
        XCTAssertEqual(transcript.rows[0].turnIDs.count, 2)
        // Editing again still covers both original turns.
        transcript.edit(rowID: block.id, text: "We can send the plan on Wednesday.", speakerName: "Jamie")
        XCTAssertEqual(edits.count, 1); XCTAssertEqual(edits[0].end, 9)
        XCTAssertEqual(transcript.rows.count, 2)
    }

    func testTimelineOnlyShrinksAudioThatOutranTheClock() {
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 100, wallSeconds: 80), 0.8, accuracy: 0.0001)
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 100, wallSeconds: 100.5), 1)
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 80, wallSeconds: 100), 1)
        XCTAssertEqual(LiveMeetingTranscriptReader.wallClockScale(fileSeconds: 100, wallSeconds: nil), 1)
    }

    @MainActor func testNamesSeenOnTheCallBecomeChoicesAndASingleHint() {
        let transcript = LiveMeetingTranscript()
        transcript.append([
            MeetingTurn(start: 0, end: 4, speaker: "You", text: "Morning."),
            MeetingTurn(start: 5, end: 9, speaker: "Speaker 2", text: "Morning, ready?"),
        ], ownerName: "Alex Rivera", candidates: .none)
        XCTAssertNil(transcript.rows[1].suggestedName)
        transcript.updateCallParticipants(["Michelle Shih", "Alex Rivera"])
        XCTAssertEqual(transcript.rows[1].suggestedName, "Michelle Shih")
        XCTAssertEqual(transcript.rows[1].callParticipants, ["Michelle Shih"])
        XCTAssertEqual(transcript.rows[0].callParticipants, [])
        // Two other people: choices, but no guess.
        transcript.updateCallParticipants(["Michelle Shih", "Carmen DeCouto", "Alex Rivera"])
        XCTAssertNil(transcript.rows[1].suggestedName)
        XCTAssertEqual(transcript.rows[1].callParticipants, ["Michelle Shih", "Carmen DeCouto"])
        XCTAssertEqual(transcript.rows[1].speaker, "Speaker 2")
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
        // A reader who scrolled away keeps their place…
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows, follow: false)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 100, accuracy: 1)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 2, length: 6))
        // …while the live view, pinned to the newest words, follows them.
        rows.append(.init(id: "pinned", speaker: "Alex", timestamp: "8:05", text: "Still talking."))
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows, follow: true)
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.height, accuracy: 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: text.bounds.height - scroll.contentSize.height))
        rows.append(.init(id: "newer", speaker: "Alex", timestamp: "8:10", text: "We can make that change tomorrow."))
        LiveTranscriptScrollView.update(text, in: scroll, rows: rows)
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.height, accuracy: 2)
    }
}
