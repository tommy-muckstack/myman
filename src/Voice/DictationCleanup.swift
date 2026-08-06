import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DictationTone: String, CaseIterable, Identifiable {
    case casual, neutral, professional, verbatim
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .casual: "Relaxed, lowercase, light punctuation"
        case .neutral: "Clear sentence case and normal punctuation"
        case .professional: "Polished and formal"
        case .verbatim: "Preserve wording; only remove obvious fillers"
        }
    }
    var promptRules: String {
        switch self {
        case .casual: "Use lowercase; keep punctuation light; no emoji unless spoken."
        case .neutral: "Use sentence case and normal punctuation; no emoji unless spoken."
        case .professional: "Use polished sentence case, full punctuation, and a professional register."
        case .verbatim: "Preserve the speaker's wording and casing; only remove clear vocal fillers."
        }
    }
}

/// The Wispr-Flow-style polish pass: raw ASR text in, clean writing out.
/// Removes fillers, applies self-corrections ("no wait, Tuesday"), fixes
/// punctuation and capitalization. On-device (macOS 26+); below that, raw
/// text passes through untouched. Guarded: if the model's output drifts too
/// far in length from the input, we distrust it and keep the raw text.
enum DictationCleanup {
    /// The small default vocabulary that ships with My Man. People can add
    /// their own names and products in Settings.
    static let builtInVocabulary = [
        "My Man", "MuckStack",
    ]
    private static let retiredBundledVocabulary: Set<String> = [
        "snabbit", "mumbls", "whistle", "huddleup", "credo chat",
    ]

    /// User-editable vocabulary at ~/MyManBrain/vocabulary.md — one term per
    /// line. The cleanup pass restores mangled versions of these exact terms.
    static func vocabulary() -> [String] {
        let url = Brain.root.appendingPathComponent("vocabulary.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let seed = """
            # Vocabulary
            \(builtInVocabulary.joined(separator: "\n"))
            """
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Remove defaults from older My Man releases. These were never meant
        // to be a permanent product list in a person's Settings vocabulary.
        let retainedLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !retiredBundledVocabulary.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        let migrated = retainedLines.joined(separator: "\n")
        if migrated != content {
            content = migrated + (migrated.hasSuffix("\n") ? "" : "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        var terms = content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // Teammate names + company domains from the people registry — the
        // proper nouns ASR reliably mangles until it's told the spelling.
        for term in builtInVocabulary + People.vocabularyTerms() where !terms.contains(where: {
            $0.caseInsensitiveCompare(term) == .orderedSame
        }) {
            terms.append(term)
        }
        return terms
    }

    static func userVocabulary() -> [String] {
        let url = Brain.root.appendingPathComponent("vocabulary.md")
        _ = vocabulary() // creates the seed file if needed
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return content.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func setUserVocabulary(_ terms: [String]) {
        let unique = terms.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, term in
                if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                    result.append(term)
                }
            }
        let content = "# Vocabulary\n" + unique.prefix(150).joined(separator: "\n") + "\n"
        try? content.write(to: Brain.root.appendingPathComponent("vocabulary.md"),
                           atomically: true, encoding: .utf8)
    }

    /// Learn distinctive terms from text the user TYPED (ground-truth
    /// spelling): CamelCase words and capitalized names away from sentence
    /// starts. Appends new ones to vocabulary.md, capped at 150 lines.
    static func learn(from text: String) {
        var existing = vocabulary()
        let known = Set(existing.map { $0.lowercased() })
        var found: [String] = []
        let pattern = "(?<![.!?\\n]\\s)(?<!^)\\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+|[A-Z][a-z]{2,}(?:\\s[A-Z][a-z]{2,})+)\\b"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let term = ns.substring(with: match.range(at: 1))
                if !known.contains(term.lowercased()), term.count > 3 {
                    found.append(term)
                }
            }
        }
        guard !found.isEmpty, existing.count < 150 else { return }

        // Frequency gate: a term must show up in 3 separate saves before it
        // earns a vocabulary slot — one-off mentions never qualify.
        let countsURL = Brain.root.appendingPathComponent(".vocab-candidates.json")
        var counts = (try? JSONDecoder().decode([String: Int].self,
                                                from: Data(contentsOf: countsURL))) ?? [:]
        var promoted: [String] = []
        for term in Set(found) {
            let count = (counts[term] ?? 0) + 1
            counts[term] = count
            if count >= 3 {
                promoted.append(term)
                counts.removeValue(forKey: term)
            }
        }
        if let data = try? JSONEncoder().encode(counts) {
            try? data.write(to: countsURL)
        }
        guard !promoted.isEmpty else { return }
        existing.append(contentsOf: promoted.prefix(10))
        let content = "# Vocabulary\n" + existing.prefix(150).joined(separator: "\n")
        try? content.write(to: Brain.root.appendingPathComponent("vocabulary.md"),
                           atomically: true, encoding: .utf8)
    }

    /// Fraction of the output's words that also appear in the input.
    private static func wordOverlap(_ output: String, _ input: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
        }
        let outWords = words(output)
        guard !outWords.isEmpty else { return 0 }
        let inWords = words(input)
        let shared = outWords.intersection(inWords).count
        return Double(shared) / Double(outWords.count)
    }

    /// Deterministic vocabulary restoration — no LLM trust required. Slides
    /// a 1-3 word window over the text; if its normalized form fuzzy-matches
    /// a vocabulary term (edit distance ≤2, same first letter, length ≥6, or
    /// exact for shorter), the canonical spelling replaces it.
    static func applyVocabulary(_ text: String, terms: [String]) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 0, !terms.isEmpty else { return text }
        func norm(_ s: String) -> String {
            String(s.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let normalizedTerms = terms.map { (canonical: $0, key: norm($0)) }
        var result = words
        var i = 0
        while i < result.count {
            var replaced = false
            for windowSize in stride(from: min(3, result.count - i), through: 1, by: -1) {
                let window = result[i..<(i + windowSize)].joined(separator: " ")
                let key = norm(window)
                guard key.count >= 4 else { continue }
                // Preserve trailing punctuation from the window's last word.
                let punctuation = String(window.reversed().prefix(while: {
                    !$0.isLetter && !$0.isNumber
                }).reversed())
                for term in normalizedTerms {
                    let exact = key == term.key
                    let fuzzy = term.key.count >= 6
                        && key.first == term.key.first
                        && editDistance(key, term.key) <= 2
                    if exact || fuzzy {
                        result.replaceSubrange(i..<(i + windowSize),
                                               with: [term.canonical + punctuation])
                        replaced = true
                        break
                    }
                }
                if replaced { break }
            }
            i += 1
        }
        return result.joined(separator: " ")
    }

    /// Exact aliases observed from our ASR engines. Fuzzy matching is useful
    /// for small typos, but these phonetic substitutions are too far away to
    /// recover reliably with edit distance alone.
    static func canonicalizeKnownTerms(_ text: String) -> String {
        let aliases = [
            ("(?i)\\bwhisper\\s*flow\\b", "Wispr Flow"),
            ("(?i)\\bwispr\\s*flow\\b", "Wispr Flow"),
            ("(?i)\\bevent\\s*kit\\b", "EventKit"),
            ("(?i)\\bavantik\\b", "EventKit"),
            ("(?i)\\bmuck\\s*stack\\b", "MuckStack"),
            ("(?i)\\bmyman\\b", "My Man"),
        ]
        return aliases.reduce(text) { result, alias in
            guard let regex = try? NSRegularExpression(pattern: alias.0) else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(in: result, range: range,
                                                  withTemplate: alias.1)
        }
    }

    /// Preserve version numbers and remove a quote that ASR has stranded
    /// between a word and its punctuation (for example, MuckStack\".).
    static func normalizeDictationFormatting(_ text: String) -> String {
        var result = text
        let replacements = [
            ("\\b(\\d+)\\s*\\.\\s*(\\d+)\\s*\\.\\s*(\\d+)\\b", "$1.$2.$3"),
            ("([[:alnum:]])[\\\"”]([.!?,;:])", "$1$2"),
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static func deterministicCleanup(_ text: String, terms: [String]? = nil) -> String {
        let restored = applyVocabulary(canonicalizeKnownTerms(text), terms: terms ?? vocabulary())
        return applyEmoji(stripFillers(applyVoiceCommands(assembleEmails(
            normalizeDictationFormatting(restored)
        ))))
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        var previousRow = Array(0...bChars.count)
        for (i, charA) in aChars.enumerated() {
            var row = [i + 1]
            for (j, charB) in bChars.enumerated() {
                row.append(min(previousRow[j + 1] + 1, row[j] + 1,
                               previousRow[j] + (charA == charB ? 0 : 1)))
            }
            previousRow = row
        }
        return previousRow[bChars.count]
    }

    /// Deterministic email assembly: "Tommy at muckstack.com" →
    /// "tommy@muckstack.com". A stopword guard keeps ordinary "at" phrases
    /// ("meet me at muckstack.com") untouched.
    static func assembleEmails(_ text: String) -> String {
        let stopwords: Set<String> = ["me", "us", "is", "are", "was", "were", "be",
                                      "you", "him", "her", "them", "it", "look",
                                      "available", "site", "page", "deck", "meet",
                                      "details", "found", "live", "hosted", "up"]
        guard let regex = try? NSRegularExpression(
            pattern: "\\b([A-Za-z][A-Za-z0-9._-]*) at ((?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,})\\b")
        else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1))
            let domain = ns.substring(with: match.range(at: 2))
            guard !stopwords.contains(name.lowercased()) else { continue }
            let full = ns.substring(with: match.range)
            result = result.replacingOccurrences(
                of: full, with: "\(name.lowercased())@\(domain)")
        }
        return result
    }

    /// Register guidance by destination app — Slack gets chat energy, Mail
    /// gets full sentences. Neutral when unknown.
    static func toneInstruction(forBundleID bundleID: String?) -> String {
        guard let id = bundleID?.lowercased() else { return "" }
        let chat = ["slack", "messages", "discord", "telegram", "whatsapp", "signal"]
        let email = ["mail", "outlook", "spark", "superhuman", "missive"]
        if chat.contains(where: id.contains) {
            return "The text is going into a chat app: keep it casual and light — short sentences, minimal formality, no stiff punctuation."
        }
        if email.contains(where: id.contains) {
            return "The text is going into an email: complete, well-punctuated sentences with a professional register."
        }
        return ""
    }

    /// Spoken commands, applied deterministically to the final text:
    /// "new line" / "new paragraph" become breaks; "scratch that" discards
    /// everything said before it. Punctuation the cleanup added around the
    /// command words is absorbed.
    static func applyVoiceCommands(_ text: String) -> String {
        var result = text
        // scratch that → keep only what came after the LAST occurrence
        if let regex = try? NSRegularExpression(pattern: "(?i)[,.!?]?\\s*\\bscratch that\\b[,.!?]?\\s*") {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if let last = matches.last {
                result = ns.substring(from: last.range.location + last.range.length)
            }
        }
        for (pattern, replacement) in [
            ("(?i)[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\bnew line\\b[,.]?\\s*", "\n"),
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = result as NSString
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(location: 0, length: ns.length),
                    withTemplate: replacement)
            }
        }
        // Re-capitalize after breaks and trim.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// Strip LLM preamble the prompt forbids but small models still emit
    /// ("Sure, here is the cleaned text:"). Deterministic — never trust the
    /// model to follow "no preamble".
    static func stripPreamble(_ text: String) -> String {
        var result = text
        let patterns = [
            "(?is)^\\s*(sure|okay|of course|certainly|got it)?[,!. ]*\\s*here('|’)?s?( is)?\\s+(the\\s+)?clean(ed)?[ -]?(up )?(text|version|transcript)\\s*[:.\\-–—]*\\s*",
            "(?is)^\\s*clean(ed)?\\s+(text|version|transcript)\\s*[:.\\-–—]+\\s*",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = result as NSString
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "fire emoji" → 🔥, deterministically.
    static let emojiMap: [(String, String)] = [
        ("thumbs up", "👍"), ("thumbs down", "👎"), ("mind blown", "🤯"),
        ("heart eyes", "😍"), ("laughing", "😂"), ("crying", "😢"),
        ("smiley", "😊"), ("smile", "😊"), ("wink", "😉"), ("fire", "🔥"),
        ("heart", "❤️"), ("skull", "💀"), ("rocket", "🚀"), ("party", "🎉"),
        ("tada", "🎉"), ("clap", "👏"), ("eyes", "👀"), ("hundred", "💯"),
        ("check", "✅"), ("checkmark", "✅"), ("star", "⭐"), ("money", "💰"),
        ("poop", "💩"), ("pray", "🙏"), ("praying", "🙏"), ("muscle", "💪"),
        ("flex", "💪"), ("wave", "👋"), ("sunglasses", "😎"), ("cool", "😎"),
        ("salute", "🫡"), ("shrug", "🤷"), ("facepalm", "🤦"), ("lol", "😂"),
    ]

    /// Deterministic filler strip — pure vocalizations only, never words
    /// that carry meaning. Runs on every path, including the raw fallback.
    static func stripFillers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?i)(^|[.!?]\\s+|, )(um|uh|ah|er|hmm)[,.]?\\s+",
            options: []) else { return text }
        var result = text
        // Repeat until stable — handles "Ah, um, so..."
        for _ in 0..<3 {
            let ns = result as NSString
            let replaced = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: ns.length),
                withTemplate: "$1")
            if replaced == result { break }
            result = replaced
        }
        // Re-capitalize a sentence start the strip may have exposed.
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    static func applyEmoji(_ text: String) -> String {
        var result = text
        for (name, emoji) in emojiMap {
            guard let regex = try? NSRegularExpression(
                pattern: "(?i)[,.]?\\s*\\b\(NSRegularExpression.escapedPattern(for: name)) emojis?\\b[,.]?") else { continue }
            let ns = result as NSString
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: ns.length),
                withTemplate: " \(emoji)")
        }
        return result.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func clean(_ raw: String, tone: DictationTone = .neutral,
                      targetBundleID: String? = nil) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = vocabulary()
        guard trimmed.count > 12 else { return deterministicCleanup(trimmed, terms: terms) }
        // Long transcripts degrade the 3B model — it starts rewriting numbers
        // ($92,000 → "9,200") and paraphrasing (churn → "turnover"). Wrong
        // beats unpolished, so beyond this: deterministic cleanup only.
        guard trimmed.count < 1000 else {
            return deterministicCleanup(trimmed, terms: terms)
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return deterministicCleanup(trimmed, terms: terms) }
        guard case .available = SystemLanguageModel.default.availability else {
            return deterministicCleanup(trimmed, terms: terms)
        }
        let protectedTerms = terms.prefix(50).joined(separator: ", ")
        let session = LanguageModelSession(instructions: """
            You clean up dictated text. Rules, in order:
            1. Remove filler words (um, uh, ah, er, hmm, like, you know) \
            and stutters.
            2. Apply the speaker's self-corrections: "meet Tuesday — no wait, \
            Wednesday" becomes "meet Wednesday".
            3. Fix punctuation, capitalization, and obvious homophone slips \
            from context. Write spoken numbers the way a person types them: \
            "twelve hundred" → "1,200", "forty percent" → "40%", "three pm" \
            → "3pm", "march third" → "March 3rd". Spoken emails and URLs \
            become real ones: "john dot smith at gmail dot com" → \
            "john.smith@gmail.com", "muckstack dot com slash download" → \
            "muckstack.com/download".
            4. NEVER add, remove, or rephrase actual content. Keep the \
            speaker's words and tone. Output ONLY the cleaned text — no \
            preamble, no quotes.
            5. Preserve these exact proper-noun spellings when they occur or
            are clearly dictated: \(protectedTerms).
            6. Output style: \(tone.promptRules)
            """)
        do {
            // Delimited so the model can never mistake the transcript for a
            // question addressed to it (it once ANSWERED "how we doing?"
            // instead of cleaning it).
            let response = try await session.respond(to: """
                Clean up the dictated text between the markers. Output only \
                the cleaned text, nothing else.
                <<<TRANSCRIPT
                \(trimmed)
                TRANSCRIPT>>>
                """)
            var cleaned = stripPreamble(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            cleaned = cleaned
                .replacingOccurrences(of: "<<<TRANSCRIPT", with: "")
                .replacingOccurrences(of: "TRANSCRIPT>>>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Guards: sane length AND the output must be built from the
            // speaker's own words — low overlap means the model went rogue.
            guard !cleaned.isEmpty,
                  cleaned.count > trimmed.count / 3,
                  cleaned.count < trimmed.count * 2,
                  wordOverlap(cleaned, trimmed) > 0.5 else {
                return deterministicCleanup(trimmed, terms: terms)
            }
            return deterministicCleanup(cleaned, terms: terms)
        } catch {
            return deterministicCleanup(trimmed, terms: terms)
        }
        #else
        return deterministicCleanup(trimmed, terms: terms)
        #endif
    }
}
