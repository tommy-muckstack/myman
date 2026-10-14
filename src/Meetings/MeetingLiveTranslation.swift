import Combine
import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// A display-only translation of immutable speech passages. Originals remain
/// the authority for edits, checkpoints and the saved meeting transcript.
@MainActor
final class MeetingLiveTranslation: ObservableObject {
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let language: String
        let texts: [String]
    }

    @Published private(set) var request: Request?
    @Published private(set) var rows: [LiveMeetingTranscript.Row] = []
    @Published private(set) var hasFailures = false
    /// Downloads belong in System Settings, never over the recorder.
    @Published private(set) var needsDownload = false
    @Published var enabled = true { didSet { refresh() } }
    private var originals: [LiveMeetingTranscript.Row] = []
    private var translated: [String: String] = [:]
    private var languages: [String: String] = [:]
    private var failedLanguages: Set<String> = []
    private let detect: (String) -> String?

    init(detect: @escaping (String) -> String? = MeetingLiveTranslation.detectLanguage) {
        self.detect = detect
    }

    /// Short fragments ("No", "Uh", "Mm-hmm") get confident-looking but random
    /// guesses from the recognizer, which used to open language downloads for
    /// Portuguese or Croatian in an English meeting. Only substantial, clearly
    /// non-English passages leave the English pass-through.
    nonisolated static func detectLanguage(_ text: String) -> String? {
        let letters = text.filter(\.isLetter).count
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard letters >= 12, words >= 3 else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return "en" }
        return language.rawValue
    }

    func update(_ rows: [LiveMeetingTranscript.Row]) {
        originals = rows
        refresh()
    }

    func reset() {
        request = nil
        originals = []
        translated = [:]
        languages = [:]
        failedLanguages = []
        rows = []
        hasFailures = false
        needsDownload = false
    }

    func retry() {
        failedLanguages = []
        needsDownload = false
        refresh()
    }

    /// Check before creating a UI-backed session, and again after any await:
    /// stopping, switching to Original, or editing can invalidate the batch.
    @available(macOS 15.0, *)
    func prepare(_ work: Request,
                 availability: (Locale.Language, Locale.Language) async -> LanguageAvailability.Status = {
                     await LanguageAvailability().status(from: $0, to: $1)
                 }) async -> Bool {
        guard !Task.isCancelled, request?.id == work.id else { return false }
        let status = await availability(Locale.Language(identifier: work.language), Locale.Language(identifier: "en"))
        guard !Task.isCancelled, request?.id == work.id else { return false }
        switch status {
        case .installed: return true
        case .supported: skipDownload(work)
        default: fail(work)
        }
        return false
    }

    /// The worker found an installable pair. Keep displaying the original.
    func skipDownload(_ work: Request) {
        guard request?.id == work.id else { return }
        failedLanguages.insert(work.language)
        needsDownload = true
        request = nil
        refresh()
    }

    func complete(_ work: Request, translations: [String: String]) {
        guard enabled, request?.id == work.id else { return }
        for text in work.texts {
            guard let result = translations[text]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty else {
                failedLanguages.insert(work.language)
                continue
            }
            translated[text] = result
        }
        request = nil
        refresh()
    }

    func fail(_ work: Request) {
        guard request?.id == work.id else { return }
        // Don't repeatedly retry an unavailable or unsupported pair for
        // every new passage. Other languages can keep translating.
        failedLanguages.insert(work.language)
        request = nil
        refresh()
    }

    private func pieces(_ row: LiveMeetingTranscript.Row) -> [String] {
        (row.translationSegments.isEmpty ? [row.text] : row.translationSegments).flatMap { text -> [String] in
            // Human edits may be much larger than the bounded audio chunks.
            var remaining = text[...]
            var parts: [String] = []
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 1200, limitedBy: remaining.endIndex) ?? remaining.endIndex
                let boundary = end == remaining.endIndex ? end : (remaining[..<end].lastIndex(where: \.isWhitespace) ?? end)
                let cut = boundary == remaining.startIndex ? end : boundary
                parts.append(String(remaining[..<cut]))
                remaining = remaining[cut...].drop(while: \.isWhitespace)
            }
            return parts
        }
    }

    private func refresh() {
        guard enabled else { request = nil; rows = originals; hasFailures = false; return }
        let passages = originals.map(pieces)
        let current = Set(passages.flatMap { $0 })
        translated = translated.filter { current.contains($0.key) }
        languages = languages.filter { current.contains($0.key) }
        // A nil source lets Translation ask the person to choose a language.
        // Uncertain speech stays unchanged instead of opening system UI.
        for text in current where languages[text] == nil { languages[text] = detect(text) ?? "en" }
        // Keep an in-flight batch stable when more speech arrives. Its results
        // can only fill exact source passages, never overwrite corrected text.
        if let work = request, !work.texts.contains(where: current.contains) { request = nil }
        if request == nil {
            let pending = passages.flatMap { $0 }.filter {
                languages[$0] != "en" && translated[$0] == nil && !failedLanguages.contains(languages[$0] ?? "und")
            }
            if let first = pending.first {
                let language = languages[first] ?? "und"
                var seen: Set<String> = []
                let batch = pending.filter { languages[$0] == language && seen.insert($0).inserted }.prefix(4)
                request = Request(language: language, texts: Array(batch))
            }
        }
        hasFailures = current.contains { translated[$0] == nil && failedLanguages.contains(languages[$0] ?? "und") }
        rows = zip(originals, passages).map { row, pieces in
            let foreign = pieces.filter { languages[$0] != "en" }
            guard !foreign.isEmpty else { return row }
            let waiting = foreign.contains { translated[$0] == nil }
            let anyTranslated = foreign.contains { translated[$0] != nil }
            let note = waiting
                ? (anyTranslated ? "English + original" : "Original") + (foreign.contains { failedLanguages.contains(languages[$0] ?? "und") } ? " · Translation unavailable" : " · Translating…")
                : "English translation"
            return LiveMeetingTranscript.Row(id: row.id, speaker: row.speaker, timestamp: row.timestamp,
                text: pieces.map { translated[$0] ?? $0 }.joined(separator: " "), start: row.start,
                suggestedName: row.suggestedName, turnIDs: row.turnIDs, callParticipants: row.callParticipants,
                translationSegments: row.translationSegments, translationNote: note)
        }
    }
}

/// Each batch owns a session with one language pair. Recreating only the
/// invisible worker prevents new speech from cancelling a batch or moving
/// the transcript's selection/scroll position.
@available(macOS 15.0, *)
struct MeetingTranslationWorker: View {
    @ObservedObject var translation: MeetingLiveTranslation

    var body: some View {
        if let request = translation.request {
            MeetingTranslationBatch(translation: translation, request: request)
                .id(request.id)
        }
    }
}

@available(macOS 15.0, *)
private struct MeetingTranslationBatch: View {
    @ObservedObject var translation: MeetingLiveTranslation
    let request: MeetingLiveTranslation.Request
    @State private var ready = false
    @State private var activeSession: TranslationSession?

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.frame(width: 0, height: 0)
                .task {
                    guard await translation.prepare(request) else { return }
                    // Unlike translationTask, this session cannot present UI,
                    // even if the model disappears after the availability check.
                    let session = TranslationSession(installedSource: Locale.Language(identifier: request.language),
                                                     target: Locale.Language(identifier: "en"))
                    activeSession = session
                    defer { session.cancel(); activeSession = nil }
                    await translate(using: session)
                }
                .onDisappear { activeSession?.cancel() }
        } else {
            legacyWorker
        }
        #else
        legacyWorker
        #endif
    }

    /// macOS 15 requires a view-backed session. Do not even configure it
    /// until a known language pair has been confirmed installed.
    private var legacyWorker: some View {
        Color.clear.frame(width: 0, height: 0)
            .task { ready = await translation.prepare(request) }
            .translationTask(ready ? .init(source: Locale.Language(identifier: request.language),
                                          target: Locale.Language(identifier: "en")) : nil) { session in
                guard await translation.prepare(request) else { return }
                await translate(using: session)
            }
    }

    private func translate(using session: TranslationSession) async {
        do {
            try Task.checkCancellation()
            guard translation.request?.id == request.id else { return }
            let inputs = request.texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: inputs)
            try Task.checkCancellation()
            var results: [String: String] = [:]
            for response in responses {
                guard let identifier = response.clientIdentifier, let index = Int(identifier),
                      request.texts.indices.contains(index) else { continue }
                results[request.texts[index]] = response.targetText
            }
            translation.complete(request, translations: results)
        } catch {
            // A disappearing tab leaves the batch queued for its next visit.
            guard !Task.isCancelled else { return }
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), case TranslationError.notInstalled = error {
                translation.skipDownload(request)
                return
            }
            #endif
            translation.fail(request)
        }
    }
}
