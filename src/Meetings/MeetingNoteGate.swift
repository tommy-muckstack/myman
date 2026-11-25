import Foundation

/// Decides whether a meeting has enough speech to write notes from. Below this, a model
/// only invents content, so notes are not written. Thresholds follow anarlog's summary eligibility
/// (5 words and 160 characters of speech), which it uses before it calls a model.
enum MeetingNoteGate {
    static let minimumWords = 5
    static let minimumCharacters = 160

    static let tooShortMessage = "Not enough speech was recorded to write notes. Notes appear once there is a few sentences of conversation."

    static func isEnoughSpeech(words: Int, characters: Int) -> Bool {
        words >= minimumWords && characters >= minimumCharacters
    }

    /// Most key points a meeting's notes may carry, by how much was said. A short call gets a short
    /// summary (anarlog's rule: a short meeting must produce a short summary, never padded).
    static func factLimit(characters: Int) -> Int {
        switch characters {
        case ..<600: return 2
        case ..<2_000: return 4
        case ..<6_000: return 8
        default: return 12
        }
    }

    /// Normalized character count: whitespace runs count as one space, matching the word counts above.
    static func characterCount(of text: String) -> Int {
        Array(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")).count
    }
}
