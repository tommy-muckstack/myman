import Foundation
import Combine

struct DictationPersonalization: Codable, Equatable {
    struct Snippet: Codable, Identifiable, Equatable {
        var id = UUID()
        var cue: String
        var expansion: String
    }
    struct Alias: Codable, Identifiable, Equatable {
        var id = UUID()
        var term: String
        var soundsLike: [String]
    }
    struct Transform: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var instruction: String
    }
    var version = 1
    var snippets: [Snippet] = []
    var aliases: [Alias] = []
    var transforms: [Transform] = [
        .init(name: "Polish", instruction: "Fix grammar and punctuation while preserving every fact and the author's meaning."),
        .init(name: "Shorten", instruction: "Make this concise, preserving all commitments, names, numbers and dates."),
        .init(name: "Bullet points", instruction: "Organize the text into clear bullet points without adding facts.")
    ]

    func validated() throws -> Self {
        guard version == 1, snippets.count <= 500, aliases.count <= 500, transforms.count <= 50 else {
            throw PersonalizationError.invalid("Unsupported version or too many entries.")
        }
        var cues = Set<String>()
        for snippet in snippets {
            let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cue.isEmpty, cue.count <= 100, !snippet.expansion.isEmpty,
                  snippet.expansion.count <= 20_000, cues.insert(cue).inserted else {
                throw PersonalizationError.invalid("Snippet cues must be unique and 1–100 characters, with an expansion of 1–20,000 characters.")
            }
        }
        for alias in aliases {
            guard !alias.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  alias.term.count <= 150, alias.soundsLike.count <= 20,
                  alias.soundsLike.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 150 }) else {
                throw PersonalizationError.invalid("Each dictionary entry needs a term and up to 20 nonempty misheard forms.")
            }
        }
        for transform in transforms {
            guard !transform.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  transform.name.count <= 100, !transform.instruction.isEmpty, transform.instruction.count <= 4000 else {
                throw PersonalizationError.invalid("A transform needs a name and an instruction of 1–4,000 characters.")
            }
        }
        guard Set(snippets.map(\.id)).count == snippets.count,
              Set(aliases.map(\.id)).count == aliases.count,
              Set(transforms.map(\.id)).count == transforms.count else {
            throw PersonalizationError.invalid("Entry identifiers must be unique.")
        }
        return self
    }

    /// Match the original input once, longest cue first at each position.
    /// Expansions are never searched again and never interpreted as regex templates.
    static func replace(_ text: String, rules: [(String, String)]) -> String {
        let rules = rules.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
        guard !rules.isEmpty else { return text }
        let pattern = "(?i)(?<![\\p{L}\\p{N}_])(?:" + rules.map {
            NSRegularExpression.escapedPattern(for: $0.0)
        }.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let source = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let cue = source.substring(with: match.range)
            guard let rule = rules.first(where: { $0.0.caseInsensitiveCompare(cue) == .orderedSame }),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: rule.1)
        }
        return result
    }

    struct Prepared {
        var text: String
        var tokens: [(String, String)]
        func restore(_ candidate: String) -> String? {
            guard tokens.allSatisfy({ candidate.components(separatedBy: $0.0).count == 2 }) else { return nil }
            // A single pass prevents snippet contents from expanding each other.
            return DictationPersonalization.replace(candidate, rules: tokens)
        }
    }

    func prepare(_ raw: String) -> Prepared {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let tokens = snippets.enumerated().map { ("MYMANSNIPPET" + nonce + "X" + String($0.offset), $0.element.expansion) }
        let masked = Self.replace(raw, rules: zip(snippets, tokens).map { ($0.0.cue, $0.1.0) })
        let active = tokens.filter { masked.contains($0.0) }
        let aliased = Self.replace(masked, rules: aliases.flatMap { alias in alias.soundsLike.map { ($0, alias.term) } })
        return Prepared(text: aliased, tokens: active)
    }

    static func contextTerms(_ text: String) -> [String] {
        let bounded = String(text.prefix(4000))
        let pattern = #"\b(?:[A-Z][a-z]+(?:[A-Z][A-Za-z0-9]*)+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Z][a-z]+ [A-Z][a-z]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = bounded as NSString
        var seen = Set<String>()
        return regex.matches(in: bounded, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }.filter { seen.insert($0).inserted }.prefix(30).map { $0 }
    }
}

enum PersonalizationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

@MainActor final class DictationPersonalizationStore: ObservableObject {
    static let shared = DictationPersonalizationStore()
    @Published private(set) var value = DictationPersonalization()
    @Published private(set) var loadError: String?
    private let file: URL
    init(root: URL? = nil) {
        let root = root ?? VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        file = root.appendingPathComponent("DictationDelivery/personalization.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { value = try Self.decode(Data(contentsOf: file)) }
            catch { loadError = error.localizedDescription }
        }
    }
    static func decode(_ data: Data) throws -> DictationPersonalization {
        guard data.count <= 2 * 1024 * 1024 else { throw PersonalizationError.invalid("The import is larger than 2 MB.") }
        return try JSONDecoder().decode(DictationPersonalization.self, from: data).validated()
    }
    func save(_ next: DictationPersonalization) throws {
        guard loadError == nil else { throw PersonalizationError.invalid("Existing personalization could not be read. It has been preserved; repair the file before saving.") }
        let next = try next.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        _ = try Self.decode(data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        value = next
    }
}
