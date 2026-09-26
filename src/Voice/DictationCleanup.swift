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
        var terms = userVocabulary()
        // Teammate names + company domains from the people registry — the
        // proper nouns ASR reliably mangles until it's told the spelling.
        for term in builtInVocabulary + People.vocabularyTerms() where !terms.contains(where: {
            $0.caseInsensitiveCompare(term) == .orderedSame
        }) {
            terms.append(term)
        }
        return terms
    }

    /// File-only vocabulary. Meeting task validation calls this inside its
    /// database write; consulting People here would reenter that same queue.
    static func userVocabulary(at url: URL = Brain.root.appendingPathComponent("vocabulary.md")) -> [String] {
        if !FileManager.default.fileExists(atPath: url.path) {
            let seed = """
            # Vocabulary
            \(builtInVocabulary.joined(separator: "\n"))
            """
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Remove defaults from older My Man releases once. These were never
        // meant to be a permanent product list, but a person may add them
        // back on purpose, so the cleanup must not run on every read.
        let marker = url.deletingLastPathComponent().appendingPathComponent(".vocabulary-defaults-retired")
        if !FileManager.default.fileExists(atPath: marker.path) {
            let retainedLines = content.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !retiredBundledVocabulary.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            let migrated = retainedLines.joined(separator: "\n")
            if migrated != content {
                content = migrated + (migrated.hasSuffix("\n") ? "" : "\n")
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        return content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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
    static func applyVocabulary(_ text: String, terms: [String], onCorrection: ((String, String) -> Void)? = nil) -> String {
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
                    let distance = editDistance(key, term.key)
                    // Most fuzzy repairs retain the first letter, which keeps
                    // ordinary prose safe. A single-edit substitution is safe
                    // even when that first letter is wrong (Luxstack →
                    // MuckStack; Chetana → Chethana).
                    // A fuzzy repair may only span as many words as the term
                    // itself: "Amplitune C" is one mangled word plus a real
                    // one, not a two-word spelling of Amplitude.
                    let termWords = term.canonical.split(whereSeparator: \.isWhitespace).count
                    // Lengths must be close too, or a short common word
                    // swallows a longer term ("next" → "Next.js").
                    let fuzzy = term.key.count >= 6 && windowSize == termWords && (
                        (key.first == term.key.first && distance <= 2 && abs(key.count - term.key.count) <= 1)
                        || (abs(key.count - term.key.count) <= 1 && distance <= 1)
                    )
                    if exact || fuzzy {
                        let replacement = term.canonical + punctuation
                        if window != replacement { onCorrection?(window, replacement) }
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
            ("(?i)\\bhuddle\\s*upro\\s*map\\b", "HuddleUp roadmap"),
            ("(?i)\\bhuddle\\s+up\\b(?=\\s+(?:app|roadmap|sports|team|web|ios|android)\\b)", "HuddleUp"),
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

    /// Everything that does not need the model. Idempotent, so it runs both
    /// before the model (which then only handles corrections and wordy
    /// fillers) and again on the model's output.
    static func deterministicCleanup(_ text: String, terms: [String]? = nil) -> String {
        let terms = terms ?? vocabulary()
        let restored = applyVocabulary(canonicalizeKnownTerms(text), terms: terms)
        return applyEmoji(collapseStutters(stripFillers(applyVoiceCommands(assembleEmails(
            slugPathTerms(SpokenForms.apply(normalizeDictationFormatting(restored)), terms: terms)
        )))))
    }

    /// A multi-word term right after a "/" is a URL slug, not prose:
    /// "download/My Man" → "download/myman".
    static func slugPathTerms(_ text: String, terms: [String]) -> String {
        terms.filter { $0.contains(" ") }.reduce(text) { result, term in
            SpokenForms.replace(result, "(?i)(?<=/)\\Q\(term)\\E\\b") { groups in
                groups[0].lowercased().replacingOccurrences(of: " ", with: "")
            }
        }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
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

    /// Deterministic email assembly: "Alex at example.com" →
    /// "alex@example.com". A stopword guard keeps ordinary "at" phrases
    /// ("meet me at example.com") untouched.
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
                of: full, with: "\(name.lowercased())@\(domain.lowercased())")
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
        result = applySpokenPunctuation(result)
        // Re-capitalize after breaks and trim.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// "comma", "question mark", "open quote … close quote" become marks.
    /// "period", "full stop", and "colon" are ordinary words too ("the trial
    /// period ends"), so they count only at the end of a phrase.
    static func applySpokenPunctuation(_ text: String) -> String {
        let open = "\u{E000}", close = "\u{E001}"
        var result = text
        let always: [(String, String)] = [
            ("question mark", "?"), ("exclamation point", "!"), ("exclamation mark", "!"),
            ("comma", ","), ("semicolon", ";"),
        ]
        let endOnly: [(String, String)] = [("period", "."), ("full stop", "."), ("colon", ":")]
        for (words, mark) in always {
            result = SpokenForms.replace(result, "(?i)[ \\t]*[,;:]?[ \\t]*\\b\(words)\\b[,.;:!?]*") { _ in mark + " " }
        }
        for (words, mark) in endOnly {
            result = SpokenForms.replace(result, "(?i)[ \\t]*[,;:]?[ \\t]*\\b\(words)\\b[,.;:!?]*(?=[ \\t]*(?:$|\\n|(?-i:[A-Z])|\(open)))") { _ in mark + " " }
        }
        result = SpokenForms.replace(result, "(?i)[ \\t]*,?[ \\t]*\\b(?:open|begin|start) quote\\b[,.]?[ \\t]*") { _ in " " + open }
        result = SpokenForms.replace(result, "(?i)[,.]?[ \\t]*\\b(?:(?:close|end) quote|unquote)\\b") { _ in close }
        guard result != text else { return text }
        // Tidy the marks: no space before, one after, no doubled marks.
        for (pattern, template) in [
            ("[ \\t]+([,.;:!?])", "$1"),
            ("([,;:])[,;:]+", "$1"),
            ("([.!?])[.!?,;:]+", "$1"),
            ("[,;:]([.!?])", "$1"),
            ("[ \\t]{2,}", " "),
            ("\(open)[ \\t]+", open),
            ("[ \\t]+\(close)", close),
        ] {
            result = SpokenForms.replace(result, pattern) { groups in
                template.replacingOccurrences(of: "$1", with: groups.count > 1 ? groups[1] : "")
            }
        }
        result = result.replacingOccurrences(of: open, with: "\"").replacingOccurrences(of: close, with: "\"")
        // Capitalize a sentence the spoken mark just ended (not after a.m./p.m.).
        result = SpokenForms.replace(result, "(?<![ap]\\.m)([.!?][ \\t]+)([a-z])") { $0[1] + $0[2].uppercased() }
        return result.replacingOccurrences(of: " \n", with: "\n").trimmingCharacters(in: .whitespaces)
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
        // Pure vocalizations anywhere in a sentence ("So um I was", "that uh
        // we"). "ah"/"er" stay start-only: "ER" and "Ah, I see" carry meaning.
        var result = SpokenForms.replace(text, "(?i)[ \\t]*,?[ \\t]*\\b(?:u+m+|u+h+|uhm|hm+|mm+)\\b[,.]?(?=[ \\t]|$)") { _ in "" }
        result = result.trimmingCharacters(in: .whitespaces)
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

    /// "it's it's not" → "it's not". Grammatical doubles ("had had",
    /// "that that") stay; words separated by punctuation are deliberate.
    static func collapseStutters(_ text: String) -> String {
        let keep: Set<String> = ["had", "that", "is", "do", "bye", "ha", "very", "no"]
        return SpokenForms.replace(text, "(?i)\\b([A-Za-z]+(?:'[A-Za-z]+)?)[ \\t]+\\1\\b") { groups in
            keep.contains(groups[1].lowercased()) ? groups[0] : groups[1]
        }
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

    /// Recognition already supplies sentence case and punctuation. Avoid a
    /// second generation for ordinary neutral prose; keep it for requested
    /// styles, self-corrections, and spoken-number formatting.
    static func requiresModelPolish(_ text: String, tone: DictationTone) -> Bool {
        if tone == .verbatim { return false }
        if tone != .neutral { return true }
        let special = #"(?i)\b(no wait|i mean|rather|scratch that|make that|actually|sorry|wait|you know|kind of|sort of|i just i|like,)"#
        return text.first?.isUppercase != true || ![".", "?", "!"].contains(text.last.map(String.init) ?? "")
            || text.range(of: special, options: .regularExpression) != nil
    }

    static func boundedPolish(fallback: String, seconds: Double = 0.9,
                              operation: @escaping @Sendable () async throws -> String) async -> String {
        (try? await AsyncDeadline.run(seconds: seconds, operation: operation)) ?? fallback
    }

    /// The model's time budget. Warm calls take ~0.5–1 s on Apple silicon;
    /// longer dictations get a little more before we fall back to rules.
    static func polishDeadline(for text: String) -> Double {
        min(2.5, 1.2 + Double(text.count) / 500)
    }

    private static let correctionCue = #"(?i)\b(no wait|actually,? no|make that|scratch that|sorry,? i mean|i mean to say|wait)\b"#
    private static let removableWords: Set<String> = [
        "um", "uh", "hmm", "like", "you", "know", "so", "i", "mean", "just", "actually", "no", "wait",
        "sorry", "make", "that", "kind", "sort", "of", "well", "okay", "ok", "basically", "literally",
    ]

    /// Share of the speaker's meaningful words the model threw away. Filler
    /// and correction words may go; content words should survive. Without an
    /// explicit correction cue, dropping more than a fifth is a rewrite.
    static func droppedContent(_ output: String, from input: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let kept = words(output)
        let meaningful = words(input).subtracting(removableWords)
        guard !meaningful.isEmpty else { return 0 }
        return Double(meaningful.subtracting(kept).count) / Double(meaningful.count)
    }

    static func acceptsPolish(_ output: String, from input: String) -> Bool {
        let limit = input.range(of: correctionCue, options: .regularExpression) != nil ? 0.5 : 0.2
        return !output.isEmpty && output.count > input.count / 3 && output.count < input.count * 2
            && wordOverlap(output, input) > 0.5 && droppedContent(output, from: input) <= limit
            && preservesStructure(output, from: input)
    }

    /// The rules already placed quotes, brackets, and numbers; the model may
    /// drop a replaced number in a correction but must not unbalance marks
    /// or invent digits.
    static func preservesStructure(_ output: String, from input: String) -> Bool {
        for mark in ["\"", "(", ")"] where output.components(separatedBy: mark).count != input.components(separatedBy: mark).count {
            return false
        }
        func numbers(_ s: String) -> Set<String> {
            Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init))
        }
        return numbers(output).isSubset(of: numbers(input))
    }

    static func instructions(tone: DictationTone, terms: [String]) -> String {
        """
        You clean up dictated text. Rules, in order:
        1. Remove filler words (um, uh, like, you know, I mean when it is \
        filler) and stutters or restarts ("I just I want" → "I just want").
        2. Apply the speaker's self-corrections: "meet Tuesday — no wait, \
        Wednesday" becomes "meet Wednesday"; "send it to Sam, sorry I mean \
        Jess" becomes "send it to Jess". Drop only the replaced part.
        3. Fix punctuation, capitalization, and obvious homophone slips from \
        context. Numbers, emails, and links are already formatted: copy digits, \
        symbols, and addresses exactly.
        4. NEVER add, remove, or rephrase actual content. Every sentence and \
        clause the speaker meant must stay, including a leading label or \
        heading. Keep the speaker's words and tone. Output ONLY the cleaned \
        text — no preamble, no quotes.
        5. Preserve these exact proper-noun spellings when they occur or are \
        clearly dictated: \(terms.prefix(50).joined(separator: ", ")).
        6. Output style: \(tone.promptRules)
        """
    }

    static func clean(_ raw: String, tone: DictationTone = .neutral,
                      targetBundleID: String? = nil) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = vocabulary()
        // Rules first: the model then sees formatted numbers, links, and
        // punctuation, and only has corrections and wordy fillers left to do.
        let prepared = deterministicCleanup(trimmed, terms: terms)
        guard prepared.count > 12, prepared.count < 1000,
              requiresModelPolish(trimmed, tone: tone) else {
            PreparedPolish.shared.discard()
            return prepared
        }
        // Long transcripts degrade the 3B model — it starts rewriting numbers
        // ($92,000 → "9,200") and paraphrasing (churn → "turnover"). Wrong
        // beats unpolished, so beyond 1,000 characters: rules only.
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return prepared }
        guard case .available = SystemLanguageModel.default.availability else { return prepared }
        let session = PreparedPolish.shared.take(tone: tone)
            ?? LanguageModelSession(instructions: instructions(tone: tone, terms: terms))
        // Delimited so the model can never mistake the transcript for a
        // question addressed to it (it once ANSWERED "how we doing?"
        // instead of cleaning it).
        let response = await boundedPolish(fallback: prepared, seconds: polishDeadline(for: prepared)) {
            try await session.respond(to: """
            Clean up the dictated text between the markers. Output only \
            the cleaned text, nothing else.
            <<<TRANSCRIPT
            \(prepared)
            TRANSCRIPT>>>
            """).content
        }
        var cleaned = stripPreamble(response.trimmingCharacters(in: .whitespacesAndNewlines))
        cleaned = cleaned
            .replacingOccurrences(of: "<<<TRANSCRIPT", with: "")
            .replacingOccurrences(of: "TRANSCRIPT>>>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Guards: sane length, built from the speaker's own words, and no
        // meaningful words silently dropped. Otherwise the rules-only text wins.
        guard acceptsPolish(cleaned, from: prepared) else { return prepared }
        return deterministicCleanup(cleaned, terms: terms)
        #else
        return prepared
        #endif
    }

    /// Warm the on-device model when recording starts, so the first dictation
    /// after a pause does not spend its whole budget loading the model (it
    /// timed out on every cold call before).
    static func prepare(tone: DictationTone) {
        guard tone != .verbatim else { return }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else { return }
        let terms = vocabulary()
        Task.detached(priority: .userInitiated) {
            let session = LanguageModelSession(instructions: instructions(tone: tone, terms: terms))
            session.prewarm()
            PreparedPolish.shared.store(session, tone: tone)
        }
        #endif
    }
}

/// One warmed session per dictation. Sessions keep a transcript, so each is
/// used once and then discarded.
final class PreparedPolish: @unchecked Sendable {
    static let shared = PreparedPolish()
    private let lock = NSLock()
    private var session: AnyObject?
    private var tone: DictationTone?

    func store(_ session: AnyObject, tone: DictationTone) {
        lock.lock(); defer { lock.unlock() }
        self.session = session; self.tone = tone
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        session = nil; tone = nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func take(tone: DictationTone) -> LanguageModelSession? {
        lock.lock(); defer { lock.unlock() }
        defer { session = nil; self.tone = nil }
        guard self.tone == tone else { return nil }
        return session as? LanguageModelSession
    }
    #endif
}
