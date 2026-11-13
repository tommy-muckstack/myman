import XCTest
@testable import MyMan

/// Phrases are recognized at their pauses while the person keeps talking;
/// release then only decodes the tail. Cuts must land in silence.
final class DictationStreamingTests: XCTestCase {
    private let rate = 16_000.0

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.3 }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * rate)) }

    func testCutsInsideAPauseAfterEnoughSpeech() throws {
        let audio = tone(5) + silence(0.6) + tone(2)
        let cut = try XCTUnwrap(DictationSegmenter.cut(in: audio, sampleRate: rate))
        let seconds = Double(cut) / rate
        XCTAssertGreaterThan(seconds, 5.0)
        XCTAssertLessThan(seconds, 5.6, "the cut lands inside the pause, never in speech")
    }

    func testNoCutBeforeAPhraseIsLongEnoughOrWhileThePauseIsStillGrowing() {
        XCTAssertNil(DictationSegmenter.cut(in: tone(2) + silence(0.6) + tone(1), sampleRate: rate), "too little speech before the pause")
        XCTAssertNil(DictationSegmenter.cut(in: tone(5) + silence(0.15), sampleRate: rate), "a pause still forming at the live edge")
        XCTAssertNil(DictationSegmenter.cut(in: tone(5) + silence(0.2) + tone(2), sampleRate: rate), "a breath is not a pause")
        XCTAssertNil(DictationSegmenter.cut(in: silence(8), sampleRate: rate), "no speech, nothing to recognize")
    }

    func testLongUnbrokenSpeechIsCutAtItsQuietestMoment() throws {
        var audio = tone(26)
        // A softer stretch (not silence) around 20 s.
        for index in Int(20 * rate)..<Int(20.15 * rate) { audio[index] *= 0.02 }
        let cut = try XCTUnwrap(DictationSegmenter.cut(in: audio, sampleRate: rate))
        XCTAssertEqual(Double(cut) / rate, 20.07, accuracy: 0.1)
    }
}

/// Paste routing for editors that drop synthetic keystrokes.
final class DictationPasteRoutingTests: XCTestCase {
    @MainActor func testGPUIEditorsIncludingForksPreferPaste() {
        for bundle in ["dev.zed.Zed", "app.brainz.desktop"] {
            XCTAssertTrue(DictationDelivery.prefersPaste(bundleID: bundle, bundleURL: nil), bundle)
        }
        XCTAssertFalse(DictationDelivery.prefersPaste(bundleID: "com.apple.TextEdit", bundleURL: nil))
    }

    @MainActor func testAConfirmedPasteIsVerifiedWithoutWaitingOnReadback() async {
        var pasted = false
        let target = DictationDelivery.Target(prefersPaste: true, before: nil, selection: nil, isFocused: { true }, readValue: { nil },
                                              replaceSelection: { _ in false }, typeChunk: { _ in false },
                                              paste: { pasted = true; return .confirmed })
        let outcome = await DictationDelivery.deliver("hello", to: target, copy: { _ in true }, pause: { _ in })
        XCTAssertTrue(pasted)
        XCTAssertEqual(outcome.state, "verified")
    }

    @MainActor func testThePromisedTextIsServedOnlyWhenAnAppReadsIt() async {
        let pasteboard = NSPasteboard(name: .init("myman-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setString("earlier copy", forType: .string)
        let saved = ConfirmedPaste.snapshot(pasteboard)
        let promise = ConfirmedPaste("dictated text", restoring: saved, pasteboard: pasteboard)
        XCTAssertTrue(promise.write())
        XCTAssertFalse(promise.requested)
        XCTAssertTrue(pasteboard.types?.contains(ConfirmedPaste.concealed) == true, "clipboard managers skip it")
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
        XCTAssertTrue(promise.requested, "a read is the confirmation")
        promise.restoreAfterPaste(delay: .milliseconds(10))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier copy")
    }
}
