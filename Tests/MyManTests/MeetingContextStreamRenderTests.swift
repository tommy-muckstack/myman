import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import MyMan

/// Opt-in visual review of the Notes tab with the context stream under the
/// editor, at the panel's minimum details height. Writes PNGs to the path in
/// `MAN_RENDER_CONTEXT_STREAM_DIR` (default /private/tmp).
final class MeetingContextStreamRenderTests: XCTestCase {
    private struct CannedProvider: MeetingContextProvider {
        func terms(in text: String, exclude: Set<String>, limit: Int) -> [String] { ["pricing", "Houston"] }
        func rank(_ request: MeetingContextRequest, database: DatabaseQueue) throws -> [MeetingContextCard] {
            let now = request.now
            func item(_ id: String, kind: String, title: String, body: String, days: Double) -> CaptureItem {
                CaptureItem(id: id, kind: kind, sourceID: id, rawTitle: title, generatedTitle: "", userTitle: "", body: body, summary: "",
                            metadata: "", sourcePath: kind == "brainNote" ? "/tmp/brain/\(id).md" : "", capturedAt: now.addingTimeInterval(-days * 86_400),
                            modifiedAt: now, pinned: false, excluded: false, revision: 1)
            }
            return [
                MeetingContextCard(id: "m1", item: item("m1", kind: "meeting", title: "Roadmap sync", body: "", days: 21), basis: .people,
                                   reason: "Last met 3 weeks ago · with Amy", people: ["Amy Chen"],
                                   excerpt: "Roadmap waits for the budget. Amy owns the pricing deck for Acme.", score: 5),
                MeetingContextCard(id: "b1", item: item("b1", kind: "brainNote", title: "Pricing model", body: "", days: 2), basis: .topic,
                                   reason: "Mentions: pricing, Houston", people: [], excerpt: "…tiered pricing for the Houston market with annual billing…", score: 3),
                MeetingContextCard(id: "n1", item: item("n1", kind: "note", title: "Acme call prep", body: "", days: 5), basis: .topic,
                                   reason: "Mentions: pricing", people: [], excerpt: "Questions to ask about pricing approvals and the timeline.", score: 2),
                MeetingContextCard(id: "s1", item: item("s1", kind: "screenshot", title: "Screenshot · Oct 1", body: "", days: 8), basis: .meaning,
                                   reason: "Related meaning", people: [], excerpt: "Budget review slide", score: 1)
            ]
        }
    }

    @MainActor func testRenderNotesTabWithStream() async throws {
        guard ProcessInfo.processInfo.environment["MAN_RENDER_CONTEXT_STREAM"] == "1" else {
            throw XCTSkip("Opt-in visual review of the meeting context stream")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let directory = ProcessInfo.processInfo.environment["MAN_RENDER_CONTEXT_STREAM_DIR"] ?? "/private/tmp"
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let meeting = Meeting(id: "call", title: "Pricing review", startedAt: Date(), transcript: "")
        try await db.write { try meeting.insert($0) }
        let draft = MeetingRecordingNote(database: db)
        draft.reset(meetingID: meeting.id)
        let stream = MeetingContextStream(provider: CannedProvider())
        stream.start(session: .init(meetingID: "call", startedAt: Date(), title: "Pricing review", attendees: [], ownerName: "Tommy"), database: db)
        for _ in 0..<50 where stream.cards.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stream.cards.count, 4)

        let window = DocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: VStack(spacing: MM.Layout.spacing / 2) {
            MeetingRecordingTabs(selection: .constant(.notes))
            MeetingRecordingNoteView(draft: draft, context: stream) { _ in }
                .frame(height: 290)
        }.padding(MM.Layout.padding).background(MM.Colors.background))
        func capture(_ name: String) throws {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(directory)/myman-context-stream-\(name).png"))
        }
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(400))
        try capture("dark")
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(400))
        try capture("light")
    }
}
