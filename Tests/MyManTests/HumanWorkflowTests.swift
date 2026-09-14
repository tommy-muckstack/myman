import XCTest
import AppKit
import ApplicationServices
@testable import MyMan

final class HumanWorkflowTests: XCTestCase {
    @MainActor func testOptInDictationDeliveryToSyntheticEditor() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_VERIFY_DICTATION_DELIVERY"] == "enabled" else { throw XCTSkip("Requires the explicitly launched synthetic editor fixture.") }
        let target = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" })
        let pid = target.processIdentifier
        guard AXIsProcessTrusted() else { throw NSError(domain: "Accessibility permission required; no text inserted", code: 1) }
        target.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(for: .milliseconds(300))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw NSError(domain: "Synthetic target did not receive focus; no text inserted", code: 1) }
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        guard let focused else { throw NSError(domain: "No synthetic target window", code: 1) }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        guard (title as? String ?? "").contains("my-man-dictation-check") else { throw NSError(domain: "Unexpected editor document; no text inserted", code: 1) }
        let outcome = await DictationDelivery.deliver("Synthetic 👩🏽‍💻 recovery check.")
        XCTAssertEqual(outcome.state, "verified", outcome.reason)
        XCTAssertGreaterThanOrEqual(outcome.milliseconds, 100)
    }

    func testProtocolIntegerSchemaRejectsFractionsBooleansAndOutOfBoundsValues() throws {
        let schema: [String: Any] = ["type": "integer", "minimum": 60, "maximum": 604800]
        try AgentSchema.validate(60, schema: schema)
        try AgentSchema.validate(604800, schema: schema)
        for value: Any in [true, 59, 60.5, 604801, "60"] { XCTAssertThrowsError(try AgentSchema.validate(value, schema: schema)) }
    }

    @MainActor func testDictationReplacementAndChunksPreserveUnicodeAndRejectInvalidSelection() {
        XCTAssertEqual(DictationDelivery.replacement(before: "Hi old friend", range: NSRange(location: 3, length: 3), text: "👩🏽‍💻"), "Hi 👩🏽‍💻 friend")
        XCTAssertNil(DictationDelivery.replacement(before: "Hi", range: NSRange(location: -1, length: 0), text: "wrong"))
        XCTAssertNil(DictationDelivery.replacement(before: "Hi", range: NSRange(location: 1, length: 20), text: "wrong"))
        let text = String(repeating: "👩🏽‍💻 café 中文 ", count: 15)
        XCTAssertEqual(DictationDelivery.chunks(text).joined(), text)
    }
    @MainActor func testRecoveryPersistsCorrectionsAndHonorsSourceDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var learned = ""
        let store = DictationHistory(root: root, learn: { learned = $0 })
        try store.save(.init(id: "one", text: "Original", targetBundle: "example.editor", createdAt: Date(), outcome: .init(state: "unverified", reason: "Inspect first", milliseconds: 120)))
        try store.correct("one", text: "Corrected product name")
        XCTAssertEqual(learned, "Corrected product name")
        let reopened = DictationHistory(root: root, learn: { _ in })
        XCTAssertEqual(reopened.entries.first?.correctedText, learned)
        reopened.purge(itemID: "dictation-one")
        XCTAssertTrue(DictationHistory(root: root, learn: { _ in }).entries.isEmpty)
    }
    func testAppWritingStyleDoesNotChangeOtherAppsOrGlobalDefault() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        DictationAppStyles.set(.verbatim, for: "example.terminal", defaults: defaults)
        XCTAssertEqual(DictationAppStyles.tone(for: "example.terminal", fallback: .professional, defaults: defaults), .verbatim)
        XCTAssertEqual(DictationAppStyles.tone(for: "example.mail", fallback: .professional, defaults: defaults), .professional)
        DictationAppStyles.set(nil, for: "example.terminal", defaults: defaults)
        XCTAssertEqual(DictationAppStyles.tone(for: "example.terminal", fallback: .neutral, defaults: defaults), .neutral)
    }
    @MainActor func testDecisionRequiresUniqueEvidenceHumanReviewAndCurrentSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = CaptureItem(id: "meeting-one", kind: "meeting", sourceID: "one", rawTitle: "Checkout review", generatedTitle: "", userTitle: "", body: "**Alex** [00:10]: We agreed to launch the checkout on Tuesday.\n\n**Sam** [00:22]: I will prepare the release checklist.", summary: "", metadata: "", sourcePath: "", capturedAt: Date(), modifiedAt: Date(), pinned: false, excluded: false, revision: 1)
        let store = MeetingDecisions(root: root, lookup: { $0 == source.id ? source : nil })
        XCTAssertThrowsError(try store.add(sourceID: source.id, revision: 1, topic: "Checkout", text: "Launch Friday", quote: "We agreed to launch on Friday."))
        let value = try store.add(sourceID: source.id, revision: 1, topic: "Checkout launch", text: "Launch Tuesday", quote: "We agreed to launch the checkout on Tuesday.")
        XCTAssertEqual(value.timestamp, "00:10")
        XCTAssertThrowsError(try store.followup(ids: [value.id], relatedIDs: []))
        try store.confirm(value.id)
        let draft = try store.followup(ids: [value.id], relatedIDs: [])
        XCTAssertTrue(draft.contains("00:10")); XCTAssertTrue(draft.contains("meeting-one"))
        source.revision = 2
        XCTAssertThrowsError(try store.followup(ids: [value.id], relatedIDs: []))
        store.purge(itemID: source.id); XCTAssertTrue(store.decisions.isEmpty)
    }
    @MainActor func testSpeakerCorrectionChangesLabelsNotQuotedNames() throws {
        let original = "**Speaker 1** [00:10]: Speaker 1 is the label in this example.\n\n**Speaker 2** [00:20]: Understood."
        let corrected = try MeetingDecisions.renameSpeaker(in: original, from: "Speaker 1", to: "Alex")
        XCTAssertTrue(corrected.hasPrefix("**Alex** [00:10]: Speaker 1"))
        XCTAssertTrue(corrected.contains("**Speaker 2** [00:20]"))
        XCTAssertThrowsError(try MeetingDecisions.renameSpeaker(in: original, from: "Speaker 1", to: "Bad\nname"))
    }
    @MainActor func testSelectedContextIncludesAllKindsAndRejectsHiddenContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = AgentMediaStore(root: root)
        var items = ["note", "dictation", "meeting"].map { kind in CaptureItem(id: kind + "-one", kind: kind, sourceID: "one", rawTitle: kind, generatedTitle: "", userTitle: "", body: "Synthetic \(kind) source", summary: "", metadata: "", sourcePath: "", capturedAt: Date(), modifiedAt: Date(), pinned: false, excluded: false, revision: 1) }
        let result = try WorkflowContext.export(ids: items.map(\.id), lookup: { id in items.first { $0.id == id } }, media: media)
        let attachments = try XCTUnwrap(result["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1); XCTAssertEqual(result["host_delivery"] as? String, "not_sent")
        let text = try String(contentsOfFile: try XCTUnwrap(attachments[0]["path"] as? String), encoding: .utf8)
        for item in items { XCTAssertTrue(text.contains(item.body)) }
        items[0].excluded = true
        XCTAssertThrowsError(try WorkflowContext.export(ids: [items[0].id], lookup: { _ in items[0] }, media: media))
        XCTAssertThrowsError(try WorkflowContext.export(ids: [], media: media))
    }
    @MainActor func testUnreadableRecoveryHistoryIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("DictationDelivery/history.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt fixture".utf8).write(to: file)
        let store = DictationHistory(root: root, learn: { _ in })
        XCTAssertThrowsError(try store.save(.init(id: "new", text: "new", targetBundle: "", createdAt: Date(), outcome: .init(state: "clipboard", reason: "", milliseconds: 0))))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt fixture")
    }
    @MainActor func testActivityReceiptsKeepReferencesAcrossRestartAndPurgeThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentJournal(root: root)
        let args: [String: Any] = ["id": "note-fixture", "body": "private text", "expected_revision": 1]
        let inputs = WorkflowActivity.references(args)
        XCTAssertNil(inputs["body"])
        try journal.begin("one", action: "note.update", fingerprint: Data(), owner: "fixture", inputs: inputs)
        XCTAssertTrue(journal.finish("one", job: ["id": "one", "action": "note.update", "owner": "fixture", "state": "succeeded", "result": ["id": "note-fixture"]]))
        let reopened = AgentJournal(root: root)
        XCTAssertEqual((reopened.job("one")?["inputs"] as? [String: Any])?["id"] as? String, "note-fixture")
        XCTAssertNotNil(reopened.job("one")?["finished_at"])
        reopened.purgeContent(); XCTAssertNil(reopened.job("one")?["inputs"])
    }
    @MainActor func testShareConfigurationRejectsCredentialBearingAndInsecureEndpoints() throws {
        XCTAssertEqual(try SharePublishing.validEndpoint("https://sharing.example/"), "https://sharing.example")
        for endpoint in ["http://example.com", "https://name:secret@example.com", "https://example.com/path", "https://example.com?token=secret", "https://example.com/#secret"] { XCTAssertThrowsError(try SharePublishing.validEndpoint(endpoint)) }
    }
    func testScrollingStitchMatchesOverlapAndPreservesAllPixels() throws {
        let width = 160, height = 480
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt64 = 42
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: random >> 32)
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let full = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let first = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: 240))!
        let next = full.cropping(to: CGRect(x: 0, y: 120, width: width, height: 240))!
        guard case .appended(let joined, let shift) = try ScrollStitcher.append(previous: first, next: next, composite: first) else { return XCTFail("Expected overlapping sections to join") }
        XCTAssertEqual(shift, 120); XCTAssertEqual(joined.height, 360)
        XCTAssertTrue(ScrollStitcher.signature(joined) == ScrollStitcher.signature(full.cropping(to: CGRect(x: 0, y: 0, width: width, height: 360))!), "Joined pixels must preserve the full source")
        guard case .unchanged = try ScrollStitcher.append(previous: first, next: first, composite: first) else { return XCTFail("An unchanged viewport must not be appended twice") }
    }
}
