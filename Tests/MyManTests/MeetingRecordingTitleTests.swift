import XCTest
import GRDB
import AppKit
import SwiftUI
@testable import MyMan

final class MeetingRecordingTitleTests: XCTestCase {
    @MainActor private func fixture(persisted: Bool = true) throws -> (MeetingController, DatabaseQueue) {
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        let meeting = Meeting(id: "live", title: "Calendar meeting", startedAt: Date().addingTimeInterval(-20),
                              transcript: "Existing transcript", summary: "My notes")
        if persisted { try queue.write { try meeting.insert($0) } }
        let controller = MeetingController(recording: meeting, titleDatabase: queue)
        controller.levels = Array(repeating: 0.8, count: 16)
        return (controller, queue)
    }

    private func saved(_ queue: DatabaseQueue) throws -> Meeting? {
        try queue.read { try Meeting.fetchOne($0, key: "live") }
    }

    @MainActor private func waitForSavedTitle(_ title: String, in queue: DatabaseQueue) async throws {
        // SwiftUI must first deliver its text change, then the debounce runs.
        // A fixed sleep incorrectly couples correctness to runner/render speed.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try saved(queue)?.title != title, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try saved(queue)?.title, title)
    }

    @MainActor func testRenameUpdatesActiveTakeAndSearchWithoutOverwritingContent() throws {
        let (controller, queue) = try fixture()
        controller.updateRecordingTitle("  Search redesign  ")
        XCTAssertEqual(controller.recordingTitle, "Search redesign")
        XCTAssertEqual(try saved(queue)?.title, "Calendar meeting")
        controller.flushRecordingTitle()
        let meeting = try XCTUnwrap(saved(queue))
        XCTAssertEqual(meeting.title, "Search redesign")
        XCTAssertEqual(meeting.transcript, "Existing transcript")
        XCTAssertEqual(meeting.summary, "My notes")
        XCTAssertNil(meeting.endedAt)
        XCTAssertEqual(CaptureIndex.item("meeting-live", database: queue)?.rawTitle, "Search redesign")
        XCTAssertEqual(try CaptureIndex.lexical("Search redesign", database: queue).first?.id, "meeting-live")
    }

    @MainActor func testTypingAutosavesLatestName() async throws {
        let (controller, queue) = try fixture()
        controller.updateRecordingTitle("Search")
        controller.updateRecordingTitle("Search design")
        try await waitForSavedTitle("Search design", in: queue)
        XCTAssertEqual(try saved(queue)?.title, "Search design")
    }

    @MainActor func testBlankDraftPreservesLastNameAndFinishingFlushesPendingEdit() throws {
        let (controller, queue) = try fixture()
        controller.updateRecordingTitle("New name")
        controller.updateRecordingTitle(" \n ")
        controller.setTitleEditorVisible(true)
        controller.finishTitleEditing()
        XCTAssertEqual(try saved(queue)?.title, "New name")
        XCTAssertFalse(controller.titleEditorVisible)
        guard case .recording = controller.phase else { return XCTFail("Editing stopped the recording") }
    }

    @MainActor func testDeletedOrProvisionalMeetingIsNeverInsertedByRename() throws {
        let (controller, queue) = try fixture(persisted: false)
        controller.isProvisional = true
        controller.updateRecordingTitle("Unsaved take")
        controller.flushRecordingTitle()
        XCTAssertNil(try saved(queue))
        controller.setTitleEditorVisible(true)
        XCTAssertFalse(controller.titleEditorVisible)
        controller.isProvisional = false
        controller.updateRecordingTitle("Deleted take")
        controller.flushRecordingTitle()
        XCTAssertNil(try saved(queue))
        XCTAssertNil(CaptureIndex.item("meeting-live", database: queue))
    }

    @MainActor func testIdlePillCannotExpand() throws {
        let (controller, _) = try fixture()
        controller.phase = .idle
        controller.setTitleEditorVisible(true)
        controller.updateRecordingTitle("Unexpected change")
        XCTAssertFalse(controller.titleEditorVisible)
        XCTAssertEqual(controller.recordingTitle, "Calendar meeting")
    }

    @MainActor func testRenderRecordingPillAndFocusableEditor() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let (controller, queue) = try fixture()
        for expanded in [false, true] {
            controller.setTitleEditorVisible(expanded)
            let panel = FloatingPanel(content: MeetingPillView(controller: controller), becomesKey: true, fixedSize: true)
            panel.becomesKeyOnlyIfNeeded = true
            panel.dismissesOnResign = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.isReleasedWhenClosed = false
            let size = MeetingController.pillSize(provisional: false, editingTitle: expanded)
            panel.setFrame(NSRect(origin: .zero, size: size), display: false)
            let host = try XCTUnwrap(panel.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/man-recording-title-\(expanded ? "expanded" : "compact").png"))
            XCTAssertEqual(host.bounds.size, size)
            XCTAssertTrue(panel.canBecomeKey)
            if expanded {
                func textField(in view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.isEditable { return field }
                    return view.subviews.lazy.compactMap { textField(in: $0) }.first
                }
                let field = try XCTUnwrap(textField(in: host))
                XCTAssertTrue(panel.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.insertText("Live edited name", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                try await waitForSavedTitle("Live edited name", in: queue)
                XCTAssertEqual(controller.recordingTitle, "Live edited name")
                XCTAssertEqual(try saved(queue)?.title, "Live edited name")
                guard case .recording = controller.phase else { return XCTFail("Typing stopped recording") }
            }
            var cancelled = false
            panel.onCancel = { cancelled = true }
            panel.cancelOperation(nil)
            XCTAssertTrue(cancelled)
            panel.contentView = nil
            panel.close()
        }
    }
    @MainActor func testExpansionKeepsControlsAnchoredAtIntermediateHeights() async throws {
        _ = NSApplication.shared
        let (controller, _) = try fixture()
        controller.setTitleEditorVisible(true)
        let panel = FloatingPanel(content: MeetingPillView(controller: controller), fixedSize: true)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        var topPixels: Data?
        for height in [44.0, 120, 260, 444] {
            // Match the native animation's invariant: top and right edges stay put.
            panel.setFrame(NSRect(x: 500, y: 600 - height, width: 400, height: height), display: false)
            let host = try XCTUnwrap(panel.contentView); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let scale = CGFloat(image.width) / 400
            // Exclude the lower corners, where the card intentionally unfolds.
            let controls = try XCTUnwrap(image.cropping(to: CGRect(x: 28 * scale, y: 8 * scale, width: 358 * scale, height: 24 * scale)))
            let pixels = try XCTUnwrap(NSBitmapImageRep(cgImage: controls).representation(using: .png, properties: [:]))
            if let topPixels { XCTAssertEqual(pixels, topPixels, "Recording controls moved during expansion") }
            else { topPixels = pixels }
            XCTAssertEqual(panel.frame.maxY, 600)
        }
    }


    @MainActor func testRenderPopulatedTranscriptAndLinkedNoteTabs() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let (controller, _) = try fixture()
        let turns: [MeetingTurn] = (0..<12).map { index in
            let start = Double(index * 10)
            return MeetingTurn(start: start, end: start + 5, speaker: index % 2 == 0 ? "You" : "Speaker 2",
                               text: index % 2 == 0 ? "Let’s review the launch plan and agree on next steps." : "I’ll send the revised proposal by Friday.")
        }
        controller.liveTranscript.append(turns, ownerName: "Alex", candidates: SpeakerCandidates(names: ["Jamie"], fromAttendees: true))
        controller.recordingNote.update("Ask Jamie about the launch timeline.\n\nSend the updated proposal after the call.")
        XCTAssertTrue(controller.recordingNote.flush())
        controller.setTitleEditorVisible(true)
        for showingNote in [false, true] {
            let window = FloatingPanel(content: MeetingPillView(controller: controller, showingNote: showingNote), becomesKey: true, fixedSize: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            let size = MeetingController.pillSize(provisional: false, editingTitle: true)
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            let host = try XCTUnwrap(window.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = "/private/tmp/myman-recorder-\(showingNote ? "note" : "transcript").png"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
