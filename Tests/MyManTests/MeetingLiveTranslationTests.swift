import AppKit
import SwiftUI
import Translation
import XCTest
@testable import MyMan

final class MeetingLiveTranslationTests: XCTestCase {
    @MainActor private func row(_ text: String, pieces: [String] = []) -> LiveMeetingTranscript.Row {
        .init(id: "remote-5", speaker: "Carmen", timestamp: "0:05", text: text, start: 5,
              turnIDs: ["turn-1"], translationSegments: pieces)
    }

    @MainActor func testNewSpeechDoesNotCancelInFlightPassageOrRetranslatePreviousSpeech() throws {
        let model = MeetingLiveTranslation(detect: { _ in "es" })
        model.update([row("Buenos días.", pieces: ["Buenos días."])])
        let first = try XCTUnwrap(model.request)
        model.update([row("Buenos días. Revisemos el plan.", pieces: ["Buenos días.", "Revisemos el plan."])])
        XCTAssertEqual(model.request?.id, first.id)
        model.complete(first, translations: ["Buenos días.": "Good morning."])
        XCTAssertEqual(model.request?.texts, ["Revisemos el plan."])
        XCTAssertEqual(model.rows.first?.text, "Good morning. Revisemos el plan.")
        XCTAssertEqual(model.rows.first?.translationNote, "English + original · Translating…")
        let second = try XCTUnwrap(model.request)
        model.complete(second, translations: ["Revisemos el plan.": "Let's review the plan."])
        XCTAssertNil(model.request)
        XCTAssertEqual(model.rows.first?.text, "Good morning. Let's review the plan.")
        XCTAssertEqual(model.rows.first?.speaker, "Carmen")
        XCTAssertEqual(model.rows.first?.timestamp, "0:05")
        XCTAssertEqual(model.rows.first?.turnIDs, ["turn-1"])
        model.enabled = false
        XCTAssertEqual(model.rows.first?.text, "Buenos días. Revisemos el plan.")
        XCTAssertNil(model.rows.first?.translationNote)
        model.enabled = true
        XCTAssertNil(model.request, "Switching back should reuse completed passages")
    }

    @MainActor func testMixedLanguagesUseSeparateSessionsAndEnglishPassesThrough() throws {
        let model = MeetingLiveTranslation(detect: { $0 == "Hola." ? "es" : $0 == "Bonjour." ? "fr" : "en" })
        model.update([row("Hola. Yes. Bonjour.", pieces: ["Hola.", "Yes.", "Bonjour."])])
        let spanish = try XCTUnwrap(model.request)
        XCTAssertEqual(spanish.language, "es")
        XCTAssertEqual(spanish.texts, ["Hola."])
        model.complete(spanish, translations: ["Hola.": "Hello."])
        let french = try XCTUnwrap(model.request)
        XCTAssertEqual(french.language, "fr")
        model.complete(french, translations: ["Bonjour.": "Good morning."])
        XCTAssertEqual(model.rows.first?.text, "Hello. Yes. Good morning.")
        XCTAssertNil(model.request)
    }

    @MainActor func testCorrectionAndNewMeetingRejectStaleResponses() throws {
        let model = MeetingLiveTranslation(detect: { _ in "es" })
        model.update([row("El martes.")])
        let old = try XCTUnwrap(model.request)
        model.update([row("El jueves.")])
        let corrected = try XCTUnwrap(model.request)
        XCTAssertNotEqual(old.id, corrected.id)
        model.complete(old, translations: ["El martes.": "On Tuesday."])
        XCTAssertEqual(model.rows.first?.text, "El jueves.")
        model.reset()
        model.update([row("El jueves.")])
        model.complete(corrected, translations: ["El jueves.": "On Thursday."])
        XCTAssertEqual(model.rows.first?.text, "El jueves.")
        XCTAssertNotEqual(model.request?.id, corrected.id)
    }

    @MainActor func testFailureDoesNotRepeatDownloadPromptsAndRetryResumes() throws {
        let model = MeetingLiveTranslation(detect: { _ in "es" })
        model.update([row("Hola.")])
        model.fail(try XCTUnwrap(model.request))
        model.update([row("Hola. Más palabras.", pieces: ["Hola.", "Más palabras."])])
        XCTAssertNil(model.request)
        XCTAssertTrue(model.hasFailures)
        XCTAssertEqual(model.rows.first?.text, "Hola. Más palabras.")
        XCTAssertEqual(model.rows.first?.translationNote, "Original · Translation unavailable")
        model.retry()
        XCTAssertNotNil(model.request)
        XCTAssertFalse(model.hasFailures)
        let work = try XCTUnwrap(model.request)
        model.enabled = false
        model.complete(work, translations: ["Hola.": "Hello.", "Más palabras.": "More words."])
        XCTAssertEqual(model.rows.first?.text, "Hola. Más palabras.")
    }

    @MainActor func testTranscriptEditsAlwaysUseOriginalAndStopClearsTranslations() throws {
        let transcript = LiveMeetingTranscript()
        transcript.append([.init(start: 5, end: 10, speaker: "Speaker 2", text: "Vamos a revisar el proyecto mañana por la tarde.")],
                          ownerName: "Alex", candidates: .none)
        let original = try XCTUnwrap(transcript.rows.first)
        let work = try XCTUnwrap(transcript.translation.request)
        transcript.translation.complete(work, translations: [original.text: "We will review the project tomorrow afternoon."])
        XCTAssertEqual(transcript.rows.first?.text, original.text)
        XCTAssertTrue(transcript.corrections.isEmpty)
        transcript.edit(rowID: original.id, text: "Vamos a revisar el proyecto el viernes.", speakerName: "Carmen")
        XCTAssertEqual(transcript.corrections.first?.text, "Vamos a revisar el proyecto el viernes.")
        XCTAssertEqual(transcript.translation.rows.first?.speaker, "Carmen")
        XCTAssertFalse(transcript.translation.rows.first?.text.contains("tomorrow") ?? true)
        transcript.stop()
        XCTAssertTrue(transcript.translation.rows.isEmpty)
        XCTAssertNil(transcript.translation.request)
    }

    func testLanguageDetection() {
        XCTAssertEqual(MeetingLiveTranslation.detectLanguage("Vamos a revisar el proyecto mañana por la tarde."), "es")
        XCTAssertEqual(MeetingLiveTranslation.detectLanguage("Nous allons examiner le projet demain après-midi."), "fr")
        XCTAssertEqual(MeetingLiveTranslation.detectLanguage("We will review the project tomorrow afternoon."), "en")
    }

    @MainActor func testInstalledSpanishTranslationReachesLiveTab() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_TRANSLATION_SMOKE"] == "1" else {
            throw XCTSkip("Opt in to testing the installed Apple translation model")
        }
        guard #available(macOS 15.0, *) else { throw XCTSkip("Requires macOS 15") }
        let availability = await LanguageAvailability().status(from: Locale.Language(identifier: "es"), to: Locale.Language(identifier: "en"))
        guard availability == .installed else { throw XCTSkip("Spanish–English model is not installed on this Mac") }
        _ = NSApplication.shared
        let transcript = LiveMeetingTranscript()
        var turns = [MeetingTurn(start: 5, end: 10, speaker: "Speaker 2", text: "Vamos a revisar el proyecto mañana por la tarde.")]
        if let path = ProcessInfo.processInfo.environment["MYMAN_TRANSLATION_AUDIO_FIXTURE"] {
            let reader = LiveMeetingTranscriptReader(micURL: nil, systemURL: URL(fileURLWithPath: path), singleRemote: true)
            try await reader.prepare()
            while await reader.hasUnreadAudio() { _ = try await reader.next(final: true) }
            turns = await reader.savedTurns()
            XCTAssertTrue(turns.map(\.text).joined(separator: " ").lowercased().contains("proyecto"), "Expected Spanish recognition from the synthetic audio")
        }
        transcript.append(turns, ownerName: "Alex", candidates: .none)
        let original = try XCTUnwrap(transcript.rows.first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: MeetingLiveTranscriptView(transcript: transcript, retry: {}))
        window.orderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while transcript.translation.request != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(transcript.translation.hasFailures)
        XCTAssertNil(transcript.translation.request)
        let output = try XCTUnwrap(transcript.translation.rows.first)
        XCTAssertEqual(output.translationNote, "English translation")
        XCTAssertTrue(output.text.lowercased().contains("project"), output.text)
        XCTAssertEqual(transcript.rows.first?.text, original.text)
        XCTAssertEqual(output.timestamp, original.timestamp)
    }

    @MainActor func testTranslationLayoutFixtures() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MYMAN_TRANSLATION_SCREENSHOTS"] else {
            throw XCTSkip("Set MYMAN_TRANSLATION_SCREENSHOTS to render synthetic UI fixtures")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let transcript = LiveMeetingTranscript()
        transcript.append([
            .init(start: 5, end: 10, speaker: "Speaker 2", text: "Vamos a revisar el proyecto mañana por la tarde."),
            .init(start: 12, end: 17, speaker: "You", text: "That works. I will send the updated schedule today.")
        ], ownerName: "Alex", candidates: SpeakerCandidates(names: ["Carmen"], fromAttendees: true))
        let work = try XCTUnwrap(transcript.translation.request)
        transcript.translation.complete(work, translations: [work.texts[0]: "We will review the project tomorrow afternoon."])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 330),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: MeetingLiveTranscriptView(transcript: transcript, retry: {})
                .padding(MM.Layout.padding).background(MM.Colors.background)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(dark ? "english-dark.png" : "english-light.png"))
            window.contentView = nil
            window.close()
        }
    }
}
