import XCTest
import AppKit
@testable import MyMan

final class AgentBriefTests: XCTestCase {
    private let owner = AgentPrincipal(id: "owner", name: "Coordinator", scopes: ["library"])
    private let worker = AgentPrincipal(id: "worker", name: "Developer", scopes: ["library"])
    private let reviewer = AgentPrincipal(id: "reviewer", name: "Reviewer", scopes: ["library"])
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("man-brief-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func fixture(_ id: String, kind: String, body: String = "Private transcript") -> CaptureItem {
        CaptureItem(id: id, kind: kind, sourceID: id, rawTitle: "Private title", generatedTitle: "", userTitle: "", body: body, summary: "", metadata: "", sourcePath: "/private/synthetic/" + id, capturedAt: Date(), modifiedAt: Date(), pinned: false, excluded: false, revision: 1)
    }
    @MainActor private func create(_ store: AgentBriefs) throws -> AgentBriefs.Brief {
        try AgentContext.$principal.withValue(owner) {
            try store.create(title: "Private brief", outcome: "Fix the checkout", recipe: "bug-fix", criteria: ["The checkout completes", "No duplicate orders"], sourceIDs: ["recording"], frameTimes: [1, 3])
        }
    }
    @MainActor func testWorkerReviewerAndEvidenceAreEnforcedAcrossRestarts() throws {
        let root = try root()
        let items = ["recording": fixture("recording", kind: "recording"), "result": fixture("result", kind: "screenshot")]
        let store = AgentBriefs(root: root, lookup: { items[$0] }, registered: { ["owner", "worker", "reviewer"].contains($0) }, observe: false)
        let brief = try create(store)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("AgentBriefs/state.json")).contains("Private transcript"))
        try AgentContext.$principal.withValue(owner) {
            XCTAssertThrowsError(try store.handoff(brief.id, expected: 1, worker: "worker", reviewer: "worker"))
            _ = try store.handoff(brief.id, expected: 1, worker: "worker", reviewer: "reviewer")
        }
        try AgentContext.$principal.withValue(reviewer) {
            XCTAssertThrowsError(try store.submit(brief.id, expected: 2, outputIDs: ["result"], summary: "Done"))
        }
        try AgentContext.$principal.withValue(worker) {
            XCTAssertThrowsError(try store.submit(brief.id, expected: 2, outputIDs: ["recording"], summary: "Original is not proof"))
            _ = try store.submit(brief.id, expected: 2, outputIDs: ["result"], summary: "The checkout completes exactly once.")
            XCTAssertThrowsError(try store.review(brief.id, expected: 3, checks: []))
        }
        let restored = AgentBriefs(root: root, lookup: { items[$0] }, registered: { _ in true }, observe: false)
        try AgentContext.$principal.withValue(reviewer) {
            XCTAssertEqual(try restored.read(brief.id).stage, "awaiting_review")
            XCTAssertThrowsError(try restored.review(brief.id, expected: 2, checks: []))
            XCTAssertThrowsError(try restored.review(brief.id, expected: 3, checks: [.init(criterion: 0, passed: true, evidenceIDs: [], note: "Unsupported")]))
            let checks = (0..<2).map { AgentBriefs.Check(criterion: $0, passed: true, evidenceIDs: ["result"], note: "Observed in the saved visual result") }
            let reviewed = try restored.review(brief.id, expected: 3, checks: checks)
            XCTAssertEqual(reviewed.stage, "reviewed")
            XCTAssertEqual(reviewed.revision, 4)
        }
        let outsider = AgentPrincipal(id: "other", name: "Other", scopes: ["library"])
        try AgentContext.$principal.withValue(outsider) {
            XCTAssertTrue(try restored.list().isEmpty)
            XCTAssertThrowsError(try restored.read(brief.id))
            XCTAssertThrowsError(try restored.delete(brief.id, expected: 4))
        }
    }
    @MainActor func testSourceChangesInvalidateProofAndOwnerRefreshResetsAssignments() throws {
        var items = ["recording": fixture("recording", kind: "recording"), "result": fixture("result", kind: "screenshot")]
        let store = AgentBriefs(root: try root(), lookup: { items[$0] }, registered: { _ in true }, observe: false)
        let brief = try create(store)
        try AgentContext.$principal.withValue(owner) { _ = try store.handoff(brief.id, expected: 1, worker: "worker", reviewer: "reviewer") }
        try AgentContext.$principal.withValue(worker) { _ = try store.submit(brief.id, expected: 2, outputIDs: ["result"], summary: "Changed") }
        items["result"]?.revision = 2
        try AgentContext.$principal.withValue(reviewer) {
            XCTAssertThrowsError(try store.review(brief.id, expected: 3, checks: [])) { XCTAssertEqual(($0 as? AgentError)?.code, "SOURCE_CHANGED") }
        }
        items["recording"]?.revision = 2
        try AgentContext.$principal.withValue(owner) {
            let fresh = try store.refresh(brief.id, expected: 3)
            XCTAssertEqual(fresh.stage, "draft"); XCTAssertNil(fresh.worker); XCTAssertNil(fresh.reviewer)
            XCTAssertTrue(fresh.outputs.isEmpty); XCTAssertEqual(fresh.sources.first?.revision, 2)
        }
        items["recording"]?.excluded = true; store.purge(itemID: "recording")
        XCTAssertTrue(try store.list(human: true).isEmpty)
    }
    @MainActor func testFailedChecksReturnWorkAndDuplicateCriteriaCannotPass() throws {
        let items = ["recording": fixture("recording", kind: "recording"), "result": fixture("result", kind: "screenshot")]
        let store = AgentBriefs(root: try root(), lookup: { items[$0] }, registered: { _ in true }, observe: false)
        let brief = try create(store)
        try AgentContext.$principal.withValue(owner) { _ = try store.handoff(brief.id, expected: 1, worker: "worker", reviewer: "reviewer") }
        try AgentContext.$principal.withValue(worker) { _ = try store.submit(brief.id, expected: 2, outputIDs: ["result"], summary: "Candidate") }
        try AgentContext.$principal.withValue(reviewer) {
            let good = AgentBriefs.Check(criterion: 0, passed: true, evidenceIDs: ["result"], note: "Checkout works")
            XCTAssertThrowsError(try store.review(brief.id, expected: 3, checks: [good, good]))
            let bad = AgentBriefs.Check(criterion: 1, passed: false, evidenceIDs: [], note: "Duplicate order behavior has not been demonstrated")
            let returned = try store.review(brief.id, expected: 3, checks: [good, bad])
            XCTAssertEqual(returned.stage, "changes_requested")
            XCTAssertThrowsError(try AgentBriefShare.export(returned, args: [:], lookup: { items[$0] }))
        }
    }
    @MainActor func testHumanBriefCanBeAssignedWithoutIssuingACredentialForTheHuman() throws {
        let item = fixture("recording", kind: "recording")
        let store = AgentBriefs(root: try root(), lookup: { _ in item }, registered: { _ in true }, observe: false)
        XCTAssertThrowsError(try store.create(title: "Brief", outcome: "Outcome", recipe: "bug-fix", criteria: ["Works"], sourceIDs: ["recording"], frameTimes: []))
        let brief = try store.create(title: "Brief", outcome: "Outcome", recipe: "bug-fix", criteria: ["Works"], sourceIDs: ["recording"], frameTimes: [], human: true)
        XCTAssertEqual(brief.owner, "human")
        _ = try store.handoff(brief.id, expected: 1, worker: "worker", reviewer: "reviewer", human: true)
        XCTAssertThrowsError(try AgentContext.$principal.withValue(worker) { try store.refresh(brief.id, expected: 2) })
        try store.delete(brief.id, expected: 2, human: true)
        XCTAssertTrue(try store.list(human: true).isEmpty)
    }
    @MainActor func testShareIsInertPortableAndExcludesPrivateContext() throws {
        let png = try AgentImages.png(AgentMediaStore.canvas(size: CGSize(width: 32, height: 32)) { context in
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        })
        let payload = "</textarea><script>alert('private')</script>"
        let html = String(decoding: try AgentBriefShare.html(title: payload, summary: payload, recipe: "bug-fix", media: [("image/png", png)]), as: UTF8.self)
        XCTAssertFalse(html.contains("<script>")); XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("default-src 'none'")); XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("<figure><img src=\"data:image/png;base64,"), "The selected visual must be an actual image element, not a debug description")
        XCTAssertFalse(html.contains("/private/synthetic")); XCTAssertFalse(html.contains("MYMAN_AGENT_TOKEN="))
        XCTAssertFalse(html.contains("Use this bot")); XCTAssertTrue(html.contains("Get this workflow"))
        XCTAssertThrowsError(try AgentBriefShare.botURL("javascript:alert(1)"))
        XCTAssertThrowsError(try AgentBriefShare.botURL("https://x.ai.evil.example/bot/example"))
        XCTAssertThrowsError(try AgentBriefShare.botURL("https://user:secret@x.ai/bot/example"))
        XCTAssertEqual(try AgentBriefShare.botURL("https://x.ai/bot/example"), "https://x.ai/bot/example")
    }
}
