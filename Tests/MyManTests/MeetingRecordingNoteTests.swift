import GRDB
import XCTest
import AppKit
import SwiftUI
@testable import MyMan

final class MeetingRecordingNoteTests: XCTestCase {
    @MainActor func testRenderMeetingNoteControls() async throws {
        guard ProcessInfo.processInfo.environment["MAN_RENDER_LIST_WRAPPING"] == "1" else {
            throw XCTSkip("Opt-in native meeting note visual review")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let (_, draft) = try fixture()
        draft.update("- [ ] Send the follow-up information after the meeting\n- [x] Confirm the pilot scope\n- Adoption started well and then slowed when ownership changed. Review the next steps together.")
        XCTAssertTrue(draft.flush())
        let window = DocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: VStack(spacing: MM.Layout.spacing) {
            Text("Project review").font(MM.Fonts.title).foregroundStyle(MM.Colors.textPrimary)
            MeetingRecordingTabs(showingNote: .constant(true))
            MeetingRecordingNoteView(draft: draft) { _ in }
        }.padding(MM.Layout.padding).background(MM.Colors.background))
        func capture(_ name: String) throws {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/myman-meeting-note-\(name).png"))
        }
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(300))
        try capture("saved-dark")
        try await Task.sleep(for: .milliseconds(5300))
        try capture("expired-dark")
        draft.update(draft.text + "\n- [ ] Share the revised plan")
        XCTAssertTrue(draft.flush())
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(300))
        try capture("saved-light")
    }

    func testReleaseUpgradePreservesNotesAndEarlyDevelopmentSchema() throws {
        for earlyBuild in [false, true] {
            let db = try DatabaseQueue()
            try Database.migrator.migrate(db, upTo: "v17-capture-context")
            try db.write { db in
                try db.execute(sql: "INSERT INTO note (id, title, body, createdAt, updatedAt) VALUES ('old', 'Existing', 'Keep my note', ?, ?)", arguments: [Date(), Date()])
                if earlyBuild {
                    try db.execute(sql: "ALTER TABLE note ADD COLUMN meetingID TEXT REFERENCES meeting(id) ON DELETE SET NULL")
                    try db.execute(sql: "CREATE UNIQUE INDEX note_meeting ON note(meetingID)")
                    try db.execute(sql: "ALTER TABLE meeting ADD COLUMN liveCorrectionsJSON TEXT NOT NULL DEFAULT '[]'")
                    try db.execute(sql: "CREATE TABLE voiceProfile (id TEXT PRIMARY KEY, name TEXT NOT NULL, embeddingJSON TEXT NOT NULL, updatedAt DATETIME NOT NULL)")
                    try db.execute(sql: "INSERT INTO voiceProfile VALUES ('known', 'Jamie', '[0.5]', ?)", arguments: [Date()])
                    try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v17-recording-notes')")
                }
            }
            try Database.migrator.migrate(db)
            try Database.migrator.migrate(db)
            let saved = try XCTUnwrap(db.read { try Note.fetchOne($0, key: "old") })
            XCTAssertEqual(saved.body, "Keep my note")
            XCTAssertNil(saved.meetingID)
            XCTAssertEqual(try VoiceProfiles.all(database: db).count, earlyBuild ? 1 : 0)
        }
    }

    @MainActor private func fixture() throws -> (DatabaseQueue, MeetingRecordingNote) {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: "call", title: "Project review", startedAt: Date(), transcript: "")
        try db.write { try meeting.insert($0) }
        let draft = MeetingRecordingNote(database: db)
        draft.reset(meetingID: meeting.id)
        return (db, draft)
    }

    @MainActor func testEmptyDraftNeverCreatesNoteAndTypingUpdatesOneLinkedNote() throws {
        let (db, draft) = try fixture()
        XCTAssertTrue(draft.flush())
        draft.update(" \n ")
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(try db.read { try Note.fetchCount($0) }, 0)
        draft.update("Ask about the launch date")
        XCTAssertTrue(draft.flush())
        let id = try XCTUnwrap(draft.note?.id)
        XCTAssertEqual(draft.note?.title, "Project review")
        draft.update("Ask about the launch date\nSend the proposal tomorrow.")
        XCTAssertTrue(draft.flush())
        let notes = try db.read { try Note.fetchAll($0) }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].id, id)
        XCTAssertEqual(notes[0].meetingID, "call")
        XCTAssertEqual(notes[0].body, draft.text)
        XCTAssertEqual(notes[0].title, "Project review")
        XCTAssertNotNil(CaptureIndex.item("note-" + id, database: db))
        draft.reset(meetingID: "call")
        XCTAssertEqual(draft.note?.id, id)
    }

    @MainActor func testFullNoteEditPreservesMeetingTitleAndFirstBodyLine() throws {
        let (db, draft) = try fixture()
        draft.update("- [ ] Ask about the plan")
        XCTAssertTrue(draft.flush())
        let note = try XCTUnwrap(draft.note)
        try NotesStore(database: db).updateDocument(note, body: "- [x] Ask about the plan\n- [ ] Share the proposal")
        draft.reset(meetingID: "call")
        XCTAssertEqual(draft.note?.title, "Project review")
        XCTAssertEqual(draft.text, "- [x] Ask about the plan\n- [ ] Share the proposal")
    }

    @MainActor func testClearingDraftRemovesEmptyNoteAndDiscardCancelsPendingSave() async throws {
        let (db, draft) = try fixture()
        draft.update("A temporary note")
        XCTAssertTrue(draft.flush())
        draft.update("")
        XCTAssertTrue(draft.flush())
        let clearedCount = try await db.read { try Note.fetchCount($0) }
        XCTAssertEqual(clearedCount, 0)
        draft.update("Pending save")
        XCTAssertTrue(draft.discard())
        try await Task.sleep(for: .milliseconds(400))
        let discardedCount = try await db.read { try Note.fetchCount($0) }
        XCTAssertEqual(discardedCount, 0)
    }

    @MainActor func testDeletedMeetingDoesNotReappearAndDraftRemainsAvailableOnSaveFailure() throws {
        let (db, draft) = try fixture()
        try db.write { _ = try Meeting.deleteOne($0, key: "call") }
        draft.update("Keep this thought available")
        XCTAssertFalse(draft.flush())
        XCTAssertTrue(draft.hasSaveError)
        XCTAssertEqual(draft.text, "Keep this thought available")
        XCTAssertEqual(try db.read { try Note.fetchCount($0) }, 0)
    }

    @MainActor func testDeletingMeetingPreservesPersonalNoteAndClearsLink() throws {
        let (db, draft) = try fixture()
        draft.update("My own meeting notes")
        XCTAssertTrue(draft.flush())
        try db.write { _ = try Meeting.deleteOne($0, key: "call") }
        let note = try XCTUnwrap(db.read { try Note.fetchOne($0) })
        XCTAssertNil(note.meetingID)
        XCTAssertEqual(note.body, "My own meeting notes")
    }

    @MainActor func testStopRequestKeepsRecordingAndExpandedControlsUntilDismissed() throws {
        let (db, _) = try fixture()
        let meeting = try XCTUnwrap(db.read { try Meeting.fetchOne($0, key: "call") })
        let controller = MeetingController(recording: meeting, titleDatabase: db)
        controller.setTitleEditorVisible(true)
        controller.requestStopRecording()
        XCTAssertTrue(controller.stopConfirmationVisible)
        controller.setTitleEditorVisible(false)
        XCTAssertTrue(controller.titleEditorVisible)
        guard case .recording = controller.phase else { return XCTFail("Stop request ended the meeting without confirmation") }
        controller.stopConfirmationVisible = false
        controller.setTitleEditorVisible(false)
        XCTAssertFalse(controller.titleEditorVisible)
        XCTAssertNotNil(try db.read { try Meeting.fetchOne($0, key: "call") })
    }
}
