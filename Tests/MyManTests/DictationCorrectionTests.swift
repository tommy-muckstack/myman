import AppKit
import XCTest
@testable import MyMan

final class DictationCorrectionTests: XCTestCase {
    @MainActor func testNativeToastPreview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_CORRECTION_UI_REVIEW"] else { throw XCTSkip("Opt-in toast review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let originalKey = NSApp.keyWindow
        Toast.show("Added “Anthropic” to dictionary", systemImage: "text.book.closed", actionLabel: "Undo", action: {}, duration: 5, position: .bottomRight)
        defer { Toast.dismiss() }
        try await Task.sleep(for: .milliseconds(200))
        let panel = try XCTUnwrap(NSApp.windows.first { !before.contains($0.windowNumber) && $0.isVisible })
        XCTAssertTrue(NSApp.keyWindow === originalKey, "The toast must not take typing focus")
        let host = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("dictionary-toast.png"))
    }

    func testExtractsOnlySmallCorrections() {
        let examples = [
            ("Meet at Muck stack tomorrow", "Meet at MuckStack tomorrow", "MuckStack"),
            ("Ask Anthropik about it.", "Ask Anthropic about it.", "Anthropic"),
            ("Send to tommy today", "Send to Tommy today", "Tommy"),
            ("Use kubernetees here", "Use Kubernetes here", "Kubernetes")
        ]
        for (before, after, expected) in examples {
            XCTAssertEqual(DictationCorrection.term(original: before, corrected: after), expected)
        }
        for (before, after) in [
            ("Hello", "Hello there"), ("Hello there", "Hello"),
            ("Hello there", "Hello, there!"), ("one plus one", "one plus two"),
            ("Record the meeting", "Send a message instead"),
            ("", "Anthropic"), ("Anthropic", ""),
            ("Call me", "call me")
        ] {
            XCTAssertNil(DictationCorrection.term(original: before, corrected: after), "\(before) → \(after)")
        }
    }

    func testVocabularyPersistsDeduplicatesAndUndoPreservesOtherWords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("vocabulary.md")
        XCTAssertTrue(try DictationCorrection.add("Anthropic", at: file))
        XCTAssertFalse(try DictationCorrection.add("anthropic", at: file))
        XCTAssertTrue(try DictationCorrection.add("Kubernetes", at: file))
        XCTAssertEqual(DictationCleanup.applyVocabulary("Ask Anthropik", terms: DictationCleanup.userVocabulary(at: file)), "Ask Anthropic")
        try DictationCorrection.remove("Anthropic", at: file)
        XCTAssertEqual(DictationCleanup.userVocabulary(at: file), ["Kubernetes"])
    }

    @MainActor func testSettledCorrectionIsSavedAndNotifiedOnce() async throws {
        var saved: [String] = [], notified: [String] = []
        let learner = DictationCorrectionLearner(enabled: { true }, save: { saved.append($0); return true }, notify: { notified.append($0) })
        defer { learner.cancel() }
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropi")
        learner.edited("Ask Anthropic")
        XCTAssertTrue(saved.isEmpty, "Wait for the user to finish editing")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(saved, ["Anthropic"])
        XCTAssertEqual(notified, saved)
        learner.edited("Ask Anthropics")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(saved, ["Anthropic"])
    }

    @MainActor func testCancellationAndNewDictationDiscardPendingCorrection() async throws {
        var saved: [String] = []
        let learner = DictationCorrectionLearner(enabled: { true }, save: { saved.append($0); return true }, notify: { _ in XCTFail("Stale toast") })
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropic")
        learner.begin("Another request")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(saved.isEmpty)
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropic")
        learner.cancel()
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(saved.isEmpty)
    }

    @MainActor func testDisabledExpiredAndRewrittenTextNeverLearn() async throws {
        var enabled = false
        var now = Date()
        let learner = DictationCorrectionLearner(enabled: { enabled }, save: { _ in XCTFail("Unexpected save"); return true }, notify: { _ in XCTFail("Unexpected toast") }, now: { now })
        defer { learner.cancel() }
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropic")
        enabled = true
        learner.begin("Ask Anthropik")
        now = now.addingTimeInterval(46)
        learner.edited("Ask Anthropic")
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropic")
        learner.edited("Write something entirely different")
        try await Task.sleep(for: .milliseconds(1300))
        learner.begin("Ask Anthropik")
        learner.edited("Ask Anthropic")
        enabled = false
        try await Task.sleep(for: .milliseconds(1300))
    }

    @MainActor func testDuplicateAndFailedWritesDoNotClaimSuccess() async throws {
        enum Failure: Error { case write }
        let duplicate = DictationCorrectionLearner(enabled: { true }, save: { _ in false }, notify: { _ in XCTFail("Duplicate toast") })
        let failure = DictationCorrectionLearner(enabled: { true }, save: { _ in throw Failure.write }, notify: { _ in XCTFail("False success toast") })
        defer { duplicate.cancel(); failure.cancel() }
        for learner in [duplicate, failure] {
            learner.begin("Ask Anthropik")
            learner.edited("Ask Anthropic")
        }
        try await Task.sleep(for: .milliseconds(1300))
    }
}
