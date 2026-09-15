import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingFact: Codable, Equatable, Sendable {
    var sourceID: Int
    var text: String
    var quote: String
    var importance: Int
}

struct MeetingCommitment: Codable, Equatable, Sendable {
    var sourceID: Int
    var owner: String
    var task: String
    var quote: String
    var due: String
    var confidence: Double
    var isRequest: Bool = false
    var key: String { MeetingSource.normalized(owner + " " + task) }
}

struct MeetingAnalysis: Codable, Sendable {
    var markdown: String
    var facts: [MeetingFact] = []
    var actions: [MeetingCommitment] = []
    var omittedPrivatePassages: Bool = false
    /// Candidate notes dropped because their words were not readable
    /// English — garbled recognition must never become a key point.
    var unclearPassages: Int = 0
}

enum MeetingEvidence {
    /// Readable text in the meeting's language. Recognition of a poor
    /// passage yields stray non-Latin letters ("agnıs") or word salad that
    /// no language model recognizes; promoting either into notes produces
    /// confident nonsense. Short phrases pass on the character test alone.
    static func legible(_ text: String, language: NLLanguage = .english) -> Bool {
        let allowed = CharacterSet.letters.subtracting(nonLatinLetters)
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            // ASCII plus Latin-1 accents (Renée, Müller); Latin Extended (ı, ş, ł) is
            // not English and marks a passage the recognizer could not hear.
            guard allowed.contains(scalar), scalar.value < 0x0100 else { return false }
        }
        let words = MeetingSource.words(text)
        guard words.count >= 6 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [language, .spanish, .french, .german, .portuguese, .italian, .dutch, .turkish]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return true }
        return best.key == language && best.value >= 0.5
    }

    private static let nonLatinLetters: CharacterSet = {
        var set = CharacterSet()
        for range in [0x0370...0x03FF, 0x0400...0x052F, 0x0590...0x08FF, 0x0900...0x0DFF, 0x0E00...0x0E7F,
                      0x1100...0x11FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF] {
            set.insert(charactersIn: Unicode.Scalar(range.lowerBound)!...Unicode.Scalar(range.upperBound)!)
        }
        return set
    }()

    static func containsQuote(_ quote: String, in text: String) -> Bool {
        let value = MeetingSource.normalized(quote)
        return value.count >= 12 && MeetingSource.words(value).count >= 4
            && MeetingSource.normalized(text).contains(value)
    }

    /// Model-generated source ids are hints. A unique verbatim passage is the
    /// actual provenance, so an incorrect id cannot move a claim to a speaker.
    static func source(for quote: String, in sources: [Int: MeetingSourceTurn]) -> MeetingSourceTurn? {
        let matches = sources.values.filter { containsQuote(quote, in: $0.text) }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func lemmas(_ text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var result = Set(MeetingSource.words(text).map(stem))
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag { result.formUnion(MeetingSource.words(tag.rawValue).map(stem)) }
            return true
        }
        return result
    }

    /// New nouns/numbers are where fluent summaries most often invent detail.
    /// Prefer a conservative, concrete paraphrase to ungrounded jargon.
    static func groundedWording(_ text: String, in evidence: String) -> Bool {
        let source = lemmas(evidence)
        let words = MeetingSource.words(text)
        guard !words.isEmpty else { return false }
        let numbers = words.filter { $0.contains(where: \.isNumber) }
        guard numbers.allSatisfy({ source.contains(stem($0)) }) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var supported = true
        let generic: Set<String> = ["point", "idea", "approach", "work", "change", "use", "plan", "need", "way", "item", "aspect", "ability", "abilitie", "capability", "capabilitie", "tool", "information", "process", "system", "insight", "organization", "documentation"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = stem(MeetingSource.normalized(String(text[range])))
            if tag == .noun, !generic.contains(word), lemmas(String(text[range])).isDisjoint(with: source) { supported = false }
            return supported
        }
        return supported
    }

    private static func stem(_ word: String) -> String {
        word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    static func fact(_ candidate: MeetingFact, sources: [Int: MeetingSourceTurn]) -> MeetingFact? {
        guard legible(candidate.text), legible(candidate.quote),
              let source = source(for: candidate.quote, in: sources),
              candidate.text.count >= 12, candidate.text.count <= 650,
              groundedWording(candidate.text, in: source.speaker + " " + source.text) else { return nil }
        // Accept the model's natural tendency to start with the speaker,
        // but only if it agrees with this source. The renderer owns the label.
        var result = candidate
        result.sourceID = source.id
        let names = Set(sources.values.flatMap { MeetingSource.words($0.speaker) })
        let first = MeetingSource.words(result.text).first ?? ""
        if names.contains(first) {
            let allowed = [source.speaker, source.speaker.split(separator: " ").first.map(String.init) ?? source.speaker]
            guard let name = allowed.first(where: { result.text.lowercased().hasPrefix($0.lowercased() + " ") }) else { return nil }
            let rest = result.text.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            result.text = rest.prefix(1).uppercased() + rest.dropFirst()
        } else if ["he", "she", "they", "you"].contains(first) { return nil }
        guard MeetingSource.words(result.text).count >= 4 else { return nil }
        return result
    }

    static func commitment(_ candidate: MeetingCommitment, sources: [Int: MeetingSourceTurn]) -> MeetingCommitment? {
        guard legible(candidate.quote), legible(candidate.task),
              candidate.confidence >= 0.85, let source = source(for: candidate.quote, in: sources),
              !source.timestamp.isEmpty, containsQuote(candidate.quote, in: source.text),
              !MeetingSource.genericSpeaker(candidate.owner),
              isTaskTitle(candidate.task), groundedWording(candidate.task, in: source.text) else { return nil }
        var result = candidate
        result.sourceID = source.id
        let quote = MeetingSource.normalized(candidate.quote)
        let hypothetical = ["i should", "we should", "you should", "i might", "i would", "if i", "if we", "i want to be", "i am a", "i m a", "i m still", "going to consider", "need to think"]
        guard !hypothetical.contains(where: quote.contains) else { return nil }
        let commitments = ["i will ", "i ll ", "i am going to ", "i m going to ", "let me ", "i can send ", "i can share ", "i can introduce "]
        if candidate.owner == source.speaker {
            guard commitments.contains(where: quote.contains) else { return nil }
            result.isRequest = false
        } else {
            let others = Set(sources.values.map(\.speaker)).subtracting([source.speaker])
                .filter { !MeetingSource.genericSpeaker($0) }
            let request = ["can you ", "could you ", "would you ", "would you be able to "]
            guard request.contains(where: quote.contains), others.contains(candidate.owner),
                  others.count == 1 || quote.contains(MeetingSource.normalized(candidate.owner)) else { return nil }
            result.isRequest = true
        }
        if !candidate.due.isEmpty, !quote.contains(MeetingSource.normalized(candidate.due)) || !DueDate.isTemporalExpression(candidate.due) { result.due = "" }
        return result
    }

    static func isTaskTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["\"", "“", "'"].contains(where: trimmed.hasPrefix) else { return false }
        let words = MeetingSource.words(trimmed)
        let verbs: Set<String> = ["send", "share", "review", "introduce", "simplify", "instrument", "add", "fix", "schedule", "update", "write", "check", "prepare", "submit", "follow", "book", "create", "remove", "test", "contact", "email", "call", "confirm", "publish", "deploy", "resend", "grant", "provide", "set", "build", "implement", "investigate", "finish", "deliver", "complete", "invite", "connect", "upload", "read", "compare", "design", "document", "measure", "track", "audit", "launch", "move", "resolve", "plan", "ask", "collect", "export", "arrange"]
        return (2...20).contains(words.count) && verbs.contains(words[0])
            && words.dropFirst().contains { !["it", "this", "that", "them", "the", "a", "to", "with", "up", "information", "stuff", "thing", "things", "something", "anything", "everything", "details", "work"].contains($0) }
    }
}

enum GroundedMeetingNotes {
    static func generate(_ meeting: Meeting, corrections: [String: String] = [:],
                         progress: @escaping MeetingNotesService.Progress = { _ in }) async -> MeetingAnalysis {
        let parsed = MeetingSource.parse(meeting.transcript)
        let publicSource = MeetingSource.publicTurns(parsed)
        let omitted = publicSource.count < parsed.filter { !MeetingSource.isBackchannel($0.text) }.count
        let prepared = publicSource.map { turn -> MeetingSourceTurn in
            let fixed = MeetingVocabulary.correct(turn.text, terms: DictationCleanup.userVocabulary(), aliases: corrections)
            return MeetingSourceTurn(id: turn.id, speaker: turn.speaker == "You" ? meeting.resolvedOwner : turn.speaker,
                                     timestamp: turn.timestamp, text: fixed.text)
        }
        let sources = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0) })
        var facts: [MeetingFact] = []; var actions: [MeetingCommitment] = []
        var unclear = 0
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let windows = MeetingSource.windows(prepared)
            for (index, window) in windows.enumerated() {
                guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
                await progress("Reading sources · \(index + 1) of \(windows.count)…")
                let session = LanguageModelSession(instructions: instructions(listening: meeting.captureKind == .listening))
                do {
                    let response = try await session.respond(to: window, generating: Extraction.self)
                    facts += response.content.facts.filter { $0.importance >= 2 }.compactMap {
                        let candidate = MeetingFact(sourceID: $0.sourceID, text: $0.text, quote: $0.quote, importance: $0.importance)
                        if let fact = MeetingEvidence.fact(candidate, sources: sources) { return fact }
                        // Keep the model-selected evidence if its paraphrase is
                        // unsupported. Never substitute an unrelated paragraph,
                        // and never quote a passage that is not readable.
                        guard let source = MeetingEvidence.source(for: $0.quote, in: sources),
                              (60...450).contains($0.quote.count) else { return nil }
                        guard MeetingEvidence.legible($0.quote) else { unclear += 1; return nil }
                        return MeetingFact(sourceID: source.id, text: "“\($0.quote)”", quote: $0.quote, importance: 1)
                    }
                    if meeting.captureKind != .listening {
                        actions += response.content.commitments.compactMap {
                            MeetingEvidence.commitment(MeetingCommitment(sourceID: $0.sourceID, owner: $0.owner, task: $0.task,
                                                                         quote: $0.quote, due: $0.due, confidence: $0.confidence), sources: sources)
                        }
                    }
                } catch {
                    // Keep this window represented by an attributed source
                    // excerpt, rather than silently dropping part of the recording.
                    Analytics.track("meeting_grounding_window_failed", ["window": index, "of": windows.count])
                    facts += fallbackFacts(prepared.filter { window.contains("[T\($0.id)]") }).sorted { $0.quote.count > $1.quote.count }.prefix(1)
                }
            }
        }
        #endif
        guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
        if facts.isEmpty {
            let fallback = fallbackFacts(prepared)
            facts = fallback.filter { MeetingEvidence.legible($0.quote) }
            unclear += fallback.count - facts.count
        }
        var seen = Set<String>()
        actions = actions.sorted { $0.confidence > $1.confidence }.filter { seen.insert($0.key).inserted }
        actions = Array(actions.prefix(6)).sorted { $0.sourceID < $1.sourceID }
        let selected = selectFacts(facts)
        let markdown = render(facts: selected, actions: actions, sources: sources, meeting: meeting, privateOmitted: omitted, unclear: unclear)
        let audit = publicSource.flatMap { MeetingVocabulary.correct($0.text, terms: DictationCleanup.userVocabulary(), aliases: corrections).corrections }
        let suffix = Array(Set(audit)).sorted().map { "<!-- corrected: \($0.replacingOccurrences(of: "--", with: "—")) -->" }.joined(separator: "\n")
        return MeetingAnalysis(markdown: markdown + (suffix.isEmpty ? "" : "\n\n" + suffix), facts: selected,
                               actions: actions, omittedPrivatePassages: omitted, unclearPassages: unclear)
    }

    static func selectFacts(_ facts: [MeetingFact]) -> [MeetingFact] {
        var seen = Set<String>()
        let unique = facts.filter { seen.insert(MeetingSource.normalized($0.text)).inserted }.sorted { $0.sourceID < $1.sourceID }
        guard unique.count > 10 else { return unique }
        // Preserve coverage across the whole conversation, not just its opening.
        return (0..<10).compactMap { bucket in
            let start = bucket * unique.count / 10, end = (bucket + 1) * unique.count / 10
            return unique[start..<end].max { $0.importance < $1.importance }
        }
    }

    private static func fallbackFacts(_ turns: [MeetingSourceTurn]) -> [MeetingFact] {
        turns.compactMap { turn in
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = turn.text
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: turn.text.startIndex..<turn.text.endIndex) { range, _ in
                let sentence = String(turn.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if (60...450).contains(sentence.count) { sentences.append(sentence) }
                return true
            }
            let filler: Set<String> = ["yeah", "okay", "know", "like", "think", "um", "uh", "right", "really", "just", "well", "good", "morning", "hello", "happy", "friday", "thanks", "thank"]
            func score(_ text: String) -> Int {
                let words = MeetingSource.words(text)
                let concrete = words.filter { $0.count >= 5 && !filler.contains($0) }
                return Set(concrete).count - words.filter { filler.contains($0) }.count * 2
            }
            guard let quote = sentences.max(by: { score($0) < score($1) }), score(quote) >= 4 else { return nil }
            return MeetingFact(sourceID: turn.id, text: "“\(quote)”", quote: quote, importance: 1)
        }
    }

    static func render(facts: [MeetingFact], actions: [MeetingCommitment], sources: [Int: MeetingSourceTurn],
                       meeting: Meeting, privateOmitted: Bool, unclear: Int = 0) -> String {
        func line(_ fact: MeetingFact) -> String {
            guard let source = sources[fact.sourceID] else { return "" }
            return "- \(source.speaker): \(fact.text) \(source.timestamp.isEmpty ? "(time unavailable)" : "[" + source.timestamp + "]")"
        }
        var output: String
        if meeting.captureKind == .listening {
            output = "## Takeaways\n\n" + facts.map(line).joined(separator: "\n")
        } else {
            output = "## Summary\n\n" + facts.sorted { $0.importance > $1.importance }.prefix(3).sorted { $0.sourceID < $1.sourceID }.map(line).joined(separator: "\n")
            output += "\n\n## Key points\n\n" + facts.map(line).joined(separator: "\n")
            if !actions.isEmpty {
                output += "\n\n## Action items\n\n" + actions.compactMap { action -> String? in
                    guard let source = sources[action.sourceID] else { return nil }
                    var line = "- **\(action.owner)** — \(action.task)"
                    if action.isRequest { line += " (requested)" }
                    if !action.due.isEmpty { line += " — due \(DueDate.resolve(action.due, from: meeting.startedAt) ?? action.due)" }
                    return line + " \(source.timestamp.isEmpty ? "(time unavailable)" : "[" + source.timestamp + "]")"
                }.joined(separator: "\n")
            }
        }
        if privateOmitted { output += "\n\n*Private passages omitted from these notes.*" }
        if unclear > 0 { output += "\n\n*\(unclear) unclear passage\(unclear == 1 ? " was" : "s were") left out of these notes. The transcript has the original words.*" }
        return output
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *) private static func instructions(listening: Bool) -> String {
        """
        Read these source turns and extract grounded \(listening ? "takeaways from a recording the owner listened to" : "meeting notes"). Each starts with [Tnumber], a speaker, and a timestamp.
        Return zero to four useful facts worth remembering later: concrete proposals, explanations, decisions, numbers, and outcomes. Cover the later material too. Ignore greetings, filler, calendar chit-chat, and audio checks. Return an empty facts array for small talk. A useful note states the actual proposal or explanation, not merely that somebody discussed a topic. Every fact needs its exact sourceID and a short VERBATIM quote from THAT turn. Use the speaker's concrete words; do not invent jargon, names, numbers, technology (bots are not robotics), causality, or commitments. The app supplies speaker attribution: write the fact without a leading name or pronoun. A speaker reporting somebody else's idea is not proposing it themselves. importance is 1–3, with decisions/proposals at 3.
        \(listening ? "This is passive listening, not the owner's meeting. commitments MUST be an empty list. Advice and examples are takeaways, never tasks." : "Commitments are explicit first-person promises or clear requests to a known participant for a concrete deliverable. Opinions, aspirations, suggestions, tentative ideas, things already done, personal schedules, and 'we should' are NOT actions. Usually zero or one per window. Never create an action for an unnamed Speaker. owner must be an exact supplied speaker label; sourceID must identify the person making the promise or request. Each quote must contain the explicit commitment/request verbatim. Paraphrase task as an imperative verb plus a specific object (e.g. Send the deck links); never output a quoted first-person sentence. Copy due words exactly from that SAME quote or leave empty. confidence is 0 to 1; only explicit, unambiguous evidence merits >= 0.85. Do not pad the list.")
        """
    }

    @available(macOS 26.0, *) @Generable fileprivate struct ExtractedFact {
        @Guide(description: "The integer after T in the source label, e.g. 12 from [T12].") var sourceID: Int
        @Guide(description: "Copy 4 to 20 consecutive words EXACTLY from this source utterance, including filler. Spoken content, never a speaker name.") var quote: String
        @Guide(description: "State the actual point using the source’s concrete words, e.g. The registration report should be delivered by email. Do not start with a speaker name. Do not say that somebody discussed a topic; explain the point.") var text: String
        @Guide(description: "1 for background, 2 for explanation, 3 for a specific proposal or decision.", .range(1...3)) var importance: Int
    }
    @available(macOS 26.0, *) @Generable fileprivate struct ExtractedCommitment {
        @Guide(description: "The integer after T in the turn containing the explicit promise or request.") var sourceID: Int
        @Guide(description: "Copy the exact sentence containing I'll, I will, or can you AND its deliverable. Never a speaker name.") var quote: String
        @Guide(description: "The exact speaker promising this work, or the named recipient of the direct request.") var owner: String
        @Guide(description: "Imperative verb plus specific object, paraphrasing that promise. Omit advice, suggestions, and already completed work.") var task: String
        @Guide(description: "Deadline words copied from that same sentence, or empty if unstated.") var due: String
        @Guide(description: "Certainty that this is an explicit deliverable promised by this owner.", .range(0.0...1.0)) var confidence: Double
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Extraction {
        @Guide(description: "Useful facts backed by exact quoted source evidence.", .count(0...4)) var facts: [ExtractedFact]
        @Guide(description: "Explicit promises and direct requests only. Empty when nobody commits to new work.", .count(0...2)) var commitments: [ExtractedCommitment]
    }
    #endif
}
