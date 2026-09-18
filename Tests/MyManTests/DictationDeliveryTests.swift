import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class DictationDeliveryTests: XCTestCase {
    @MainActor func testOptInZedDelivery() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYMAN_VERIFY_ZED_FILE"],
              path.hasPrefix("/private/tmp/myman-zed-delivery/"),
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("my-man-dictation-check") else {
            throw XCTSkip("Requires an explicitly opened synthetic Zed file")
        }
        XCTAssertTrue(AXIsProcessTrusted())
        guard AXIsProcessTrusted() else { return }
        let target = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "dev.zed.Zed" })
        target.activate(options: [])
        try await Task.sleep(for: .milliseconds(250))
        let app = AXUIElementCreateApplication(target.processIdentifier)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let fixture = try XCTUnwrap(windows.first {
            (attribute($0, kAXTitleAttribute) as? String)?.contains(name) == true
        })
        AXUIElementPerformAction(fixture, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(fixture, kAXMainAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(250))
        let rawWindow = try XCTUnwrap(attribute(app, kAXFocusedWindowAttribute))
        guard CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return XCTFail("No fixture window") }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        guard (attribute(window, kAXTitleAttribute) as? String)?.contains(name) == true,
              try String(contentsOfFile: path) == "Before:\n" else { return XCTFail("Unexpected fixture; no insertion") }
        let text = "Synthetic dictation 👩🏽‍💻 recovery check."
        let outcome = await DictationDelivery.deliver(text)
        XCTAssertEqual(outcome.state, "sent", outcome.reason)
        XCTAssertEqual(outcome.statusLabel, "Paste sent")
        XCTAssertFalse(outcome.isVerified, "Opaque editors cannot provide AX text confirmation")
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let current = attribute(app, kAXFocusedWindowAttribute), CFEqual(current, window) else {
            return XCTFail("Focus changed; fixture not saved")
        }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 1, keyDown: down))
            event.flags = .maskCommand; event.post(tap: .cgSessionEventTap)
        }
        let deadline = Date().addingTimeInterval(2)
        while (try? String(contentsOfFile: path)) != "Before:" + text + "\n", Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOfFile: path), "Before:" + text + "\n", "One paste must reach the fixture caret")
        print("Zed native paste fixture: \(outcome.state), \(outcome.milliseconds)ms")
    }

    func testCustomEditorsUsePasteCapabilityInsteadOfRequiringAXTextRole() async {
        await MainActor.run {
            for role in [nil, "AXWindow", "AXGroup", "AXUnknown", "AXWebArea", "AXLayoutArea"] as [String?] {
                XCTAssertEqual(DictationDelivery.insertionSupport(role: role, subrole: nil, secureInput: false,
                    hasWindow: true, pasteEnabled: true), .pasteCommand)
                XCTAssertEqual(DictationDelivery.insertionSupport(role: role, subrole: nil, secureInput: false,
                    hasWindow: true, pasteEnabled: false), .unavailable)
            }
            for role in ["AXButton", "AXOutline", "AXTable", "AXStaticText", "AXMenuItem"] {
                XCTAssertEqual(DictationDelivery.insertionSupport(role: role, subrole: nil, secureInput: false,
                    hasWindow: true, pasteEnabled: true), .unavailable)
            }
            for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
                XCTAssertEqual(DictationDelivery.insertionSupport(role: role, subrole: nil, secureInput: false,
                    hasWindow: true, pasteEnabled: false), .textField)
            }
            XCTAssertEqual(DictationDelivery.insertionSupport(role: "AXWindow", subrole: nil, secureInput: false,
                hasWindow: false, pasteEnabled: true), .unavailable)
            XCTAssertEqual(DictationDelivery.insertionSupport(role: "AXWindow", subrole: nil, secureInput: true,
                hasWindow: true, pasteEnabled: true), .unavailable)
            XCTAssertEqual(DictationDelivery.insertionSupport(role: "AXTextField", subrole: "AXSecureTextField", secureInput: false,
                hasWindow: true, pasteEnabled: true), .unavailable)
        }
    }
    @MainActor func testOptInCursorDelivery() async throws {
        guard let mode = ProcessInfo.processInfo.environment["MYMAN_VERIFY_CURSOR_DELIVERY"] else { throw XCTSkip("Requires the explicitly opened synthetic Cursor window") }
        XCTAssertTrue(AXIsProcessTrusted(), "Native delivery verification requires Accessibility")
        guard AXIsProcessTrusted() else { return }
        let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92" })
        app.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(for: .milliseconds(300))
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(300))
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let windowValue = try XCTUnwrap(attribute(application, kAXFocusedWindowAttribute))
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        let title = attribute(window, kAXTitleAttribute) as? String ?? ""
        guard title.contains("my-man-dictation-check") else { return XCTFail("Unexpected window; no text inserted") }
        // The operator focuses the empty chat/editor before opting in. Do not
        // toggle Cursor's chat shortcut here: it can close an already open input.
        let fieldValue = try XCTUnwrap(attribute(application, kAXFocusedUIElementAttribute))
        let field = unsafeBitCast(fieldValue, to: AXUIElement.self)
        let text = "Synthetic dictation 👩🏽‍💻 recovery check."
        // Make this opt-in fixture repeatable without ever erasing user text.
        if (attribute(field, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            let source = CGEventSource(stateID: .privateState)
            for (key, flags) in [(CGKeyCode(0), CGEventFlags.maskCommand), (CGKeyCode(51), CGEventFlags())] {
                for isDown in [true, false] {
                    let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown))
                    event.flags = flags; event.post(tap: .cgSessionEventTap)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let before = attribute(field, kAXValueAttribute) as? String
        print("Cursor focused role: \(attribute(field, kAXRoleAttribute) as? String ?? "unavailable"), value length: \(before?.utf16.count ?? -1)")
        guard let before, before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return XCTFail("Fixture input must be empty; no text inserted") }
        let selected = try XCTUnwrap(attribute(field, kAXSelectedTextRangeAttribute))
        var range = CFRange()
        guard CFGetTypeID(selected) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(selected, to: AXValue.self), .cfRange, &range) else { return XCTFail("No fixture caret") }
        let expected = try XCTUnwrap(DictationDelivery.replacement(before: before, range: NSRange(location: range.location, length: range.length), text: text))
        let outcome = await DictationDelivery.deliver(text)
        print("Cursor fixture (\(mode)): \(outcome.state), \(outcome.milliseconds)ms")
        let actual = attribute(field, kAXValueAttribute) as? String
        XCTAssertTrue(actual == expected || (mode == "chat" && before == "\n" && actual == text), "Synthetic text should reach the caret")
        XCTAssertEqual(outcome.state, "verified", outcome.reason)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    @MainActor private final class Editor {
        var value = "Hello old friend"
        var selection = NSRange(location: 6, length: 3)
        var focused = true
        var clipboard = "previous clipboard"
        var axWrites = 0, pastes = 0, chunks = 0, pauses = 0
        var ignoreWrites = false, copyFails = false, axSupported = true
        var pasteFails = false
        var onPause: (() -> Void)?

        func target(paste: Bool, readable: Bool = true) -> DictationDelivery.Target {
            .init(prefersPaste: paste, before: readable ? value : nil,
                  selection: readable ? selection : nil,
                  isFocused: { self.focused }, readValue: { readable ? self.value : nil },
                  replaceSelection: { text in
                      self.axWrites += 1
                      if self.axSupported && !self.ignoreWrites { self.insert(text) }
                      return self.axSupported
                  }, typeChunk: { text in
                      self.chunks += 1
                      self.insert(text)
                      return true
                  }, paste: {
                      self.pastes += 1
                      if self.pasteFails { return false }
                      if !self.ignoreWrites { self.insert(self.clipboard) }
                      return true
                  })
        }
        func insert(_ text: String) {
            value = DictationDelivery.replacement(before: value, range: selection, text: text)!
            selection = NSRange(location: selection.location + (text as NSString).length, length: 0)
        }
        func copy(_ text: String) -> Bool {
            if copyFails { return false }
            clipboard = text
            return true
        }
        func pause(_ milliseconds: Int) async { pauses += 1; onPause?() }
        func deliver(_ text: String, paste: Bool = true, readable: Bool = true) async -> DictationDelivery.Outcome {
            await DictationDelivery.deliver(text, to: target(paste: paste, readable: readable), copy: copy, pause: pause)
        }
    }

    @MainActor func testElectronPastesOnceAtSelectionWithoutAXWrite() async {
        let editor = Editor()
        let text = "👩🏽‍💻 new\nsecond line"
        let outcome = await editor.deliver(text)
        XCTAssertEqual(editor.value, "Hello \(text) friend")
        XCTAssertEqual(editor.pastes, 1)
        XCTAssertEqual(editor.axWrites, 0)
        XCTAssertEqual(editor.chunks, 0)
        XCTAssertTrue(outcome.isVerified)
        XCTAssertEqual(outcome.statusLabel, "Pasted")
    }

    @MainActor func testIgnoredAXSuccessCopiesTextWithoutRetryOrFalseSuccess() async {
        let editor = Editor(); editor.ignoreWrites = true
        let outcome = await editor.deliver("Testing the copying part of this feature.", paste: false)
        XCTAssertEqual(outcome.state, "unverified")
        XCTAssertEqual(outcome.clipboardAvailable, true)
        XCTAssertEqual(editor.clipboard, "Testing the copying part of this feature.")
        XCTAssertEqual(editor.value, "Hello old friend")
        XCTAssertEqual(editor.axWrites, 1)
        XCTAssertEqual(editor.pastes, 0)
        XCTAssertEqual(editor.chunks, 0)
        XCTAssertEqual(outcome.statusLabel, "Unconfirmed — text copied")
    }

    @MainActor func testDelayedElectronReadbackPollsWithoutPastingTwice() async {
        let editor = Editor(); editor.ignoreWrites = true
        editor.onPause = { if editor.pauses == 2 { editor.insert("new") } }
        let outcome = await editor.deliver("new")
        XCTAssertTrue(outcome.isVerified)
        XCTAssertEqual(editor.pastes, 1)
        XCTAssertEqual(editor.pauses, 2)
    }

    @MainActor func testElectronEmptyParagraphReadbackDropsPlaceholderNewline() async {
        let editor = Editor(); editor.value = "\n"; editor.selection = NSRange(location: 0, length: 0)
        editor.onPause = { editor.value = "new" }
        let outcome = await editor.deliver("new")
        XCTAssertTrue(outcome.isVerified)
        XCTAssertEqual(editor.pastes, 1)
    }

    @MainActor func testUnreadableOrIgnoredElectronResultRemainsPasteable() async {
        for readable in [true, false] {
            let editor = Editor(); editor.ignoreWrites = true
            let outcome = await editor.deliver("new", readable: readable)
            XCTAssertEqual(outcome.state, readable ? "unverified" : "sent")
            XCTAssertEqual(editor.clipboard, "new")
            XCTAssertEqual(editor.pastes, 1)
            XCTAssertFalse(outcome.isVerified)
        }
    }

    @MainActor func testFocusChangeBeforeDeliveryCopiesWithoutInserting() async {
        let editor = Editor(); editor.focused = false
        let outcome = await editor.deliver("new")
        XCTAssertEqual(outcome.state, "clipboard")
        XCTAssertEqual(editor.clipboard, "new")
        XCTAssertEqual(editor.pastes, 0)
        XCTAssertEqual(editor.axWrites, 0)
    }

    @MainActor func testOpaqueEditorPastesOnceWithoutClaimingReadbackOrShowingFailure() async {
        let editor = Editor()
        let outcome = await editor.deliver("new", readable: false)
        XCTAssertEqual(editor.value, "Hello new friend")
        XCTAssertEqual(editor.pastes, 1)
        XCTAssertEqual(editor.axWrites, 0)
        XCTAssertEqual(editor.chunks, 0)
        XCTAssertEqual(outcome.state, "sent")
        XCTAssertEqual(outcome.statusLabel, "Paste sent")
        XCTAssertFalse(outcome.isVerified)
        XCTAssertFalse(outcome.needsAttention)
        XCTAssertEqual(outcome.clipboardAvailable, true)
        XCTAssertEqual(editor.clipboard, "new")
    }

    @MainActor func testOpaqueEditorFocusChangeAfterPasteRequiresReviewWithoutRetry() async {
        let editor = Editor(); editor.onPause = { editor.focused = false }
        let outcome = await editor.deliver("new", readable: false)
        XCTAssertEqual(outcome.state, "uncertain")
        XCTAssertTrue(outcome.needsAttention)
        XCTAssertEqual(editor.pastes, 1)
    }

    @MainActor func testFocusChangeAfterPasteNeverRetries() async {
        let editor = Editor(); editor.onPause = { editor.focused = false }
        let outcome = await editor.deliver("new")
        XCTAssertEqual(outcome.state, "uncertain")
        XCTAssertEqual(editor.value, "Hello new friend")
        XCTAssertEqual(editor.clipboard, "new")
        XCTAssertEqual(editor.pastes, 1)
    }

    @MainActor func testInterruptedUnicodeInsertionKeepsFullText() async {
        let editor = Editor(); editor.axSupported = false
        editor.onPause = { editor.focused = false }
        let text = String(repeating: "Long dictation 👩🏽‍💻 ", count: 10)
        let outcome = await editor.deliver(text, paste: false)
        XCTAssertEqual(outcome.state, "uncertain")
        XCTAssertEqual(editor.chunks, 1)
        XCTAssertEqual(editor.clipboard, text)
    }

    @MainActor func testNativeVerifiedInsertionPreservesClipboard() async {
        let editor = Editor()
        let outcome = await editor.deliver("new", paste: false)
        XCTAssertTrue(outcome.isVerified)
        XCTAssertEqual(editor.clipboard, "previous clipboard")
        XCTAssertEqual(editor.pastes, 0)
    }

    @MainActor func testClipboardAndPasteFailuresDoNotClaimSuccess() async {
        let editor = Editor(); editor.copyFails = true
        let outcome = await editor.deliver("new")
        XCTAssertEqual(outcome.clipboardAvailable, false)
        XCTAssertEqual(outcome.statusLabel, "Saved — use Copy")
        XCTAssertEqual(editor.pastes, 0)
        editor.copyFails = false; editor.pasteFails = true
        let failedPaste = await editor.deliver("new")
        XCTAssertEqual(failedPaste.state, "clipboard")
        XCTAssertEqual(failedPaste.statusLabel, "Copied — ⌘V to paste")
        XCTAssertEqual(editor.clipboard, "new")
    }

    @MainActor func testExistingTextAloneCannotVerifyIgnoredInsertion() async {
        let editor = Editor(); editor.ignoreWrites = true
        let outcome = await editor.deliver("old")
        XCTAssertEqual(outcome.state, "unverified")
    }

    @MainActor func testLegacyHistoryDecodesAndOnlyVerifiedOutcomeSaysPasted() throws {
        for state in ["clipboard", "unverified", "uncertain", "verified", "sent", "future-state"] {
            let json = "{\"state\":\"\(state)\",\"reason\":\"fixture\",\"milliseconds\":129}"
            let outcome = try JSONDecoder().decode(DictationDelivery.Outcome.self, from: Data(json.utf8))
            XCTAssertEqual(outcome.statusLabel == "Pasted", state == "verified")
        }
        XCTAssertTrue(DictationDelivery.prefersPaste(bundleID: "com.todesktop.230313mzl4w4u92", bundleURL: nil))
        XCTAssertFalse(DictationDelivery.prefersPaste(bundleID: "com.apple.TextEdit", bundleURL: nil))
    }

    @MainActor func testRenderTruthfulResultPills() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        for state in ["verified", "clipboard", "unverified", "sent"] {
            let controller = VoiceController()
            controller.deliveryOutcome = .init(state: state,
                reason: state == "sent" ? "Paste sent. This app doesn’t expose its text for confirmation." : "Insertion could not be confirmed. Your text is copied; check the field before pressing ⌘V to avoid duplicates.",
                milliseconds: 420, clipboardAvailable: state != "verified")
            controller.phase = .done("Testing the copying part of this feature.")
            controller.pillPresented = true
            XCTAssertEqual(controller.resultLingerSeconds, ["verified", "sent"].contains(state) ? 3 : 12)
            let host = NSHostingView(rootView: VoicePillView(controller: controller).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 456, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 456, height: 320)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("dictation-\(state).png"))
        }
    }
}
