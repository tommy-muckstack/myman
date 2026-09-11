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

    @MainActor func testIdleAndTranscribingPillsCannotExpand() throws {
        let (controller, _) = try fixture()
        controller.phase = .idle
        controller.setTitleEditorVisible(true)
        controller.updateRecordingTitle("Unexpected change")
        XCTAssertFalse(controller.titleEditorVisible)
        XCTAssertEqual(controller.recordingTitle, "Calendar meeting")
        XCTAssertEqual(MeetingController.pillSize(provisional: false, transcribing: true, editingTitle: true), CGSize(width: 216, height: 40))
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
            let size = MeetingController.pillSize(provisional: false, transcribing: false, editingTitle: expanded)
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
}
