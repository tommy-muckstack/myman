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

    @MainActor func testOverlappingCalendarEventCannotReplaceRecordingAfterPossibleEndSignals() throws {
        let (controller, queue) = try fixture()
        let originalPhase = controller.phase
        let originalSession = controller.recordingSessionID
        controller.recordingNote.update("Notes from the original hour-long meeting")
        XCTAssertTrue(controller.recordingNote.flush())
        let originalNoteID = controller.recordingNote.note?.id

        // A quiet stretch, a hidden call window, or lost mic attribution can
        // coincide with the next calendar event. None gives it the recorder.
        for signal in ["mic_attribution", "window_closed", "app_quit"] {
            controller.handlePossibleMeetingEnd(reason: signal)
            controller.handleRecordingSilence(seconds: 1800)
            XCTAssertNil(controller.startProvisional(title: "Overlapping 30-minute meeting",
                joinURL: URL(string: "https://meet.google.com/second-call")))
            XCTAssertEqual(controller.phase, originalPhase)
            XCTAssertEqual(controller.recordingSessionID, originalSession)
            XCTAssertEqual(controller.activeCaptureMeetingID, "live")
            XCTAssertEqual(controller.recordingTitle, "Calendar meeting")
            XCTAssertEqual(controller.recordingNote.note?.id, originalNoteID)
            XCTAssertFalse(controller.canStartRecording)
            XCTAssertFalse(controller.isTranscribing)
            XCTAssertNil(controller.pendingTitle)
            XCTAssertNil(controller.provisionalJoinURL)
        }
        let stored = try XCTUnwrap(saved(queue))
        XCTAssertNil(stored.endedAt)
        XCTAssertEqual(stored.transcript, "Existing transcript")
        XCTAssertEqual(stored.summary, "My notes")
        XCTAssertEqual(try queue.read { try Meeting.fetchCount($0) }, 1)
    }

    @MainActor func testOverlappingCalendarEventCannotTakeOverPendingPermission() async {
        var reply: CheckedContinuation<Bool, Never>?
        let requested = expectation(description: "Microphone permission pending")
        let controller = MeetingController(requestMicrophoneAccess: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let firstSession = controller.startProvisional(title: "Original meeting")
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNotNil(firstSession)
        XCTAssertNil(controller.startProvisional(title: "Overlapping meeting"))
        XCTAssertEqual(controller.recordingSessionID, firstSession)
        XCTAssertEqual(controller.pendingTitle, "Original meeting")
        XCTAssertTrue(controller.isStarting)
        controller.prepareForQuit()
        reply?.resume(returning: false)
    }

    @MainActor func testDelayedCalendarCommitCannotClaimAnotherProvisionalRecording() throws {
        let (controller, queue) = try fixture(persisted: false)
        controller.isProvisional = true
        let originalPhase = controller.phase
        controller.keepProvisional(sessionID: UUID())
        XCTAssertTrue(controller.isProvisional)
        XCTAssertEqual(controller.phase, originalPhase)
        XCTAssertEqual(controller.recordingTitle, "Calendar meeting")
        XCTAssertNil(try saved(queue))
        XCTAssertNil(controller.startProvisional(title: "Overlapping event"))
    }

    @MainActor func testNotesStaysOpenAndExpandedHeightSurvivesCollapseAndNewController() throws {
        let suite = "myman.recording-layout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = Meeting(id: "resize", title: "Original meeting", startedAt: Date(), transcript: "")
        let controller = MeetingController(recording: record, recordingLayoutDefaults: defaults)
        controller.setTitleEditorVisible(true)
        controller.setNotesTabSelected(true)
        controller.setTitleEditorVisible(false, automatically: true)
        XCTAssertTrue(controller.titleEditorVisible, "Notes must stay open when the pointer or focus leaves")

        controller.beginResizingPill()
        controller.setTitleEditorVisible(false, automatically: true)
        XCTAssertTrue(controller.titleEditorVisible)
        controller.finishResizingPill(height: 680)
        XCTAssertEqual(controller.recordingPanelSize(availableHeight: 1000), CGSize(width: 400, height: 680))
        controller.finishTitleEditing()
        XCTAssertFalse(controller.titleEditorVisible, "Explicit collapse must still work with Notes selected")
        XCTAssertEqual(controller.recordingPanelSize(availableHeight: 1000), CGSize(width: 186, height: 44))
        controller.setTitleEditorVisible(true)
        XCTAssertEqual(controller.recordingPanelSize(availableHeight: 1000).height, 680)
        controller.setNotesTabSelected(false)
        controller.setTitleEditorVisible(false, automatically: true)
        XCTAssertFalse(controller.titleEditorVisible, "Transcript retains its hover-collapse behavior")
        controller.setTitleEditorVisible(true)
        XCTAssertEqual(controller.recordingPanelSize(availableHeight: 1000).height, 680)

        // A smaller display constrains the window without erasing the chosen
        // height; returning to the larger display restores it.
        XCTAssertEqual(controller.recordingPanelSize(availableHeight: 600).height, 552)
        XCTAssertEqual(controller.expandedPillHeight, 680)
        let reopened = MeetingController(recording: record, recordingLayoutDefaults: defaults)
        reopened.setTitleEditorVisible(true)
        XCTAssertEqual(reopened.recordingPanelSize(availableHeight: 1000).height, 680)
        XCTAssertEqual(reopened.activeCaptureMeetingID, record.id)
    }

    @MainActor func testResizeGripKeepsTopAndWidthAnchoredAndStaysOnScreen() {
        let original = NSRect(x: 700, y: 500, width: 400, height: 444)
        let screen = NSRect(x: 0, y: 40, width: 1200, height: 960)
        let taller = RecordingResizeGrip.resizedFrame(original, verticalDelta: 236, visibleFrame: screen)
        XCTAssertEqual(taller.height, 680)
        XCTAssertEqual(taller.maxY, original.maxY)
        XCTAssertEqual(taller.minX, original.minX)
        XCTAssertEqual(taller.width, 400)
        XCTAssertEqual(RecordingResizeGrip.resizedFrame(original, verticalDelta: -1000, visibleFrame: screen).height, 444)
        XCTAssertEqual(RecordingResizeGrip.resizedFrame(original, verticalDelta: 2000, visibleFrame: screen).minY, screen.minY + 24)
    }

    @MainActor func testNativeGripDragResizesWindowAndRemembersHeight() async throws {
        _ = NSApplication.shared
        let suite = "myman.recording-drag." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = Meeting(id: "resize-drag", title: "Meeting", startedAt: Date(), transcript: "")
        let controller = MeetingController(recording: record, recordingLayoutDefaults: defaults)
        controller.setTitleEditorVisible(true)
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let window = FloatingPanel(content: MeetingPillView(controller: controller), fixedSize: true)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.setFrame(NSRect(x: screen.minX + 30, y: screen.maxY - 24 - 444, width: 400, height: 444), display: false)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func findGrip(_ view: NSView) -> RecordingResizeGrip? {
            if let grip = view as? RecordingResizeGrip { return grip }
            return view.subviews.lazy.compactMap(findGrip).first
        }
        let grip = try XCTUnwrap(findGrip(host))
        let origin = window.frame
        let start = window.convertPoint(toScreen: grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil))
        func event(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        grip.mouseDown(with: try event(.leftMouseDown, point: start))
        XCTAssertTrue(controller.isResizingPill)
        controller.setTitleEditorVisible(false, automatically: true)
        XCTAssertTrue(controller.titleEditorVisible)
        let end = NSPoint(x: start.x, y: start.y - 150)
        grip.mouseDragged(with: try event(.leftMouseDragged, point: end))
        XCTAssertEqual(window.frame, RecordingResizeGrip.resizedFrame(origin, verticalDelta: 150, visibleFrame: screen))
        grip.mouseUp(with: try event(.leftMouseUp, point: end))
        XCTAssertFalse(controller.isResizingPill)
        XCTAssertEqual(controller.expandedPillHeight, window.frame.height)
        XCTAssertEqual(defaults.double(forKey: "meetingExpandedPanelHeight"), window.frame.height)
        XCTAssertEqual(window.frame.maxY, origin.maxY)
    }

    @MainActor func testRenderAllRecordingTabsAtCustomHeight() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (controller, _) = try fixture()
        controller.setTitleEditorVisible(true)
        controller.recordingNote.update("Review the launch plan.\n\n- [ ] Send the proposal\n- [x] Confirm the timeline")
        XCTAssertTrue(controller.recordingNote.flush())
        let turns: [MeetingTurn] = (0..<20).map { index in
            let start = Double(index * 10)
            let speaker = index % 2 == 0 ? "You" : "Speaker 2"
            return MeetingTurn(start: start, end: start + 5, speaker: speaker,
                               text: "We are reviewing the launch timeline and the next steps for the project.")
        }
        controller.liveTranscript.append(turns, ownerName: "Alex", candidates: .none)
        let screenshotFolder = URL(fileURLWithPath: folder).appendingPathComponent("slides")
        try FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        controller.slideCapture.start(meetingID: "live", folder: screenshotFolder, startedAt: startedAt)
        let screen = NSImage(size: NSSize(width: 960, height: 600), flipped: false) { rect in
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); rect.fill()
            NSColor.systemBlue.setFill(); NSRect(x: 90, y: 90, width: 140, height: 180).fill()
            NSColor.systemTeal.setFill(); NSRect(x: 300, y: 90, width: 140, height: 280).fill()
            NSColor.systemOrange.setFill(); NSRect(x: 510, y: 90, width: 140, height: 350).fill()
            ("Quarterly product review" as NSString).draw(at: NSPoint(x: 80, y: 510),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            return true
        }
        let screenshot = try XCTUnwrap(screen.cgImage(forProposedRect: nil, context: nil, hints: nil))
        await controller.slideCapture.capture(meetingID: "live", now: { startedAt.addingTimeInterval(135) }, image: { screenshot }, inspect: { _ in })
        await controller.slideCapture.capture(meetingID: "live", force: true, now: { startedAt.addingTimeInterval(155) }, image: { screenshot }, inspect: { _ in })
        for tab in MeetingRecordingTab.allCases {
            var editorHeight: CGFloat?
            for height in [444.0, 680.0] {
                let panel = FloatingPanel(content: MeetingPillView(controller: controller, selectedTab: tab), fixedSize: true)
                panel.isReleasedWhenClosed = false
                defer { panel.contentView = nil; panel.close() }
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.setFrame(NSRect(x: 100, y: 100, width: 400, height: height), display: false)
                let host = try XCTUnwrap(panel.contentView)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let grip = try XCTUnwrap(descendants(host).compactMap { $0 as? RecordingResizeGrip }.first)
                XCTAssertEqual(grip.bounds.height, 12)
                if tab == .notes {
                    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
                    let viewport = try XCTUnwrap(editor.enclosingScrollView).contentSize.height
                    if let editorHeight { XCTAssertEqual(viewport - editorHeight, 236, accuracy: 2) }
                    else { editorHeight = viewport }
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("recording-\(tab.rawValue.lowercased())-\(Int(height)).png"))
            }
        }
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
            let window = FloatingPanel(content: MeetingPillView(controller: controller, selectedTab: showingNote ? .notes : .transcript), becomesKey: true, fixedSize: true)
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
