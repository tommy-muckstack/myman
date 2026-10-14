import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class MeetingPanelTeardownTests: XCTestCase {
    @MainActor func testTeardownDismissesAttachedSheetAndReleasesTranscriptView() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_VERIFY_MEETING_PANEL"] == "1" else {
            throw XCTSkip("Opt in to native meeting panel verification")
        }
        _ = NSApplication.shared
        let panel = FloatingPanel(content: Text("Synthetic meeting"), fixedSize: true)
        panel.isReleasedWhenClosed = false
        panel.dismissesOnResign = false
        panel.setFrame(NSRect(x: 100, y: 100, width: 400, height: 444), display: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: Text("Synthetic language download"))
        defer { panel.close(); sheet.close() }
        panel.orderFront(nil)
        let dismissed = expectation(description: "Attached sheet cancelled")
        panel.beginSheet(sheet) { response in
            XCTAssertEqual(response, .cancel)
            dismissed.fulfill()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while sheet.sheetParent == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sheet.sheetParent === panel, "Wait for AppKit to present the sheet before dismissing it")
        panel.tearDown()
        await fulfillment(of: [dismissed], timeout: 2)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertNil(panel.contentView, "Release the view so its translation task cannot outlive the recording")
        XCTAssertNil(sheet.sheetParent)
    }
}
