import Foundation
import NaturalLanguage

enum MeetingLanguageGuard {
    static func hasUnexpectedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400...0x052F).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
        }
    }

    /// Retry only an isolated script switch after established English speech.
    /// An actual non-English conversation must not be silently anglicized.
    static func shouldRetryEnglish(_ text: String, preceding: String) -> Bool {
        guard hasUnexpectedScript(text), MeetingSource.words(preceding).count >= 30 else { return false }
        let foreign = MeetingSource.words(text).filter(hasUnexpectedScript)
        guard foreign.count <= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(preceding.suffix(2000)))
        return recognizer.dominantLanguage == .english
    }

    static func resolved(original: String, retried: String) -> String {
        let candidate = retried.trimmingCharacters(in: .whitespacesAndNewlines)
        return !candidate.isEmpty && !hasUnexpectedScript(candidate)
            ? candidate : "[unclear: language recognition]"
    }

    static func retryEnglish(_ samples: [Float]) async -> String {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // SpeechAnalyzer uses an explicit en-US locale. Do not reenter
            // the stateful Qwen decoder that caused earlier Core ML crashes.
            let engine = AppleSpeechEngine()
            await engine.load()
            guard engine.isReady else { return "" }
            return await engine.transcribe(samples)
        }
        #endif
        return ""
    }
}
