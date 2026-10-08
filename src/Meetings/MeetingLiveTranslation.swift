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
        let language: String?
        let texts: [String]
    }

    @Published private(set) var request: Request?
    @Published private(set) var rows: [LiveMeetingTranscript.Row] = []
    @Published private(set) var hasFailures = false
    @Published var enabled = true { didSet { refresh() } }
    private var originals: [LiveMeetingTranscript.Row] = []
    private var translated: [String: String] = [:]
    private var languages: [String: String] = [:]
    private var failedLanguages: Set<String> = []
    private let detect: (String) -> String?

    init(detect: @escaping (String) -> String? = MeetingLiveTranslation.detectLanguage) {
        self.detect = detect
    }

    nonisolated static func detectLanguage(_ text: String) -> String? {
        guard text.contains(where: \.isLetter) else { return "en" }
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
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
    }

    func retry() {
        failedLanguages = []
        refresh()
    }

    func complete(_ work: Request, translations: [String: String]) {
        guard enabled, request?.id == work.id else { return }
        for text in work.texts {
            guard let result = translations[text]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty else {
                failedLanguages.insert(work.language ?? "und")
                continue
            }
            translated[text] = result
        }
        request = nil
        refresh()
    }

    func fail(_ work: Request) {
        guard request?.id == work.id else { return }
        // Don't repeatedly request a declined download or unsupported pair
        // for every new passage. Other languages can keep translating.
        failedLanguages.insert(work.language ?? "und")
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
        for text in current where languages[text] == nil { languages[text] = detect(text) ?? "und" }
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
                let batch = pending.filter { languages[$0] == language && seen.insert($0).inserted }.prefix(language == "und" ? 1 : 4)
                request = Request(language: language == "und" ? nil : language, texts: Array(batch))
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
/// the transcript's selection/scroll position. SwiftUI owns session lifetime.
@available(macOS 15.0, *)
struct MeetingTranslationWorker: View {
    @ObservedObject var translation: MeetingLiveTranslation

    var body: some View {
        if let request = translation.request {
            Color.clear.frame(width: 0, height: 0)
                .translationTask(source: request.language.map { Locale.Language(identifier: $0) },
                                 target: Locale.Language(identifier: "en")) { session in
                    do {
                        let availability = LanguageAvailability()
                        if let language = request.language,
                           await availability.status(from: Locale.Language(identifier: language), to: Locale.Language(identifier: "en")) == .unsupported {
                            translation.fail(request)
                            return
                        }
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
                        // Switching tabs cancels the view's task. Leave the
                        // request queued so it resumes when the tab returns.
                        if !Task.isCancelled { translation.fail(request) }
                    }
                }
                .id(request.id)
        }
    }
}
