import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a note claims about the conversation. The distinction that matters
/// most to a reader: was this discussed, proposed, already true, or decided?
enum MeetingClaimKind: String, Codable, Sendable, CaseIterable {
    case discussion, proposal, existingCommitment = "existing_commitment", decision, openQuestion = "open_question"
}

struct MeetingFact: Codable, Equatable, Sendable {
    var sourceID: Int
    var text: String
    var quote: String
    var importance: Int
    /// Optional so analyses saved before kinds existed still decode.
    var kind: MeetingClaimKind? = nil
    var resolvedKind: MeetingClaimKind { kind ?? .discussion }
}

struct MeetingCommitment: Codable, Equatable, Sendable {
    var sourceID: Int
    var owner: String
    var task: String
    var quote: String
    var due: String
    var confidence: Double
    var isRequest: Bool = false
    /// "We should…" — worth returning to, but nobody owns it yet.
    var tentative: Bool? = nil
    var key: String { MeetingSource.normalized(owner + " " + task) }
    static let unassignedOwner = "Owner not assigned"
}

struct MeetingAnalysis: Codable, Sendable {
    var markdown: String
    var facts: [MeetingFact] = []
    var actions: [MeetingCommitment] = []
    var omittedPrivatePassages: Bool = false
    /// Candidate notes dropped because their words were not readable
    /// English — garbled recognition must never become a key point.
    var unclearPassages: Int = 0

    init(markdown: String, facts: [MeetingFact] = [], actions: [MeetingCommitment] = [],
         omittedPrivatePassages: Bool = false, unclearPassages: Int = 0) {
        self.markdown = markdown; self.facts = facts; self.actions = actions
        self.omittedPrivatePassages = omittedPrivatePassages; self.unclearPassages = unclearPassages
    }

    /// Analyses saved by earlier releases lack the newer fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try container.decode(String.self, forKey: .markdown)
        facts = try container.decodeIfPresent([MeetingFact].self, forKey: .facts) ?? []
        actions = try container.decodeIfPresent([MeetingCommitment].self, forKey: .actions) ?? []
        omittedPrivatePassages = try container.decodeIfPresent(Bool.self, forKey: .omittedPrivatePassages) ?? false
        unclearPassages = try container.decodeIfPresent(Int.self, forKey: .unclearPassages) ?? 0
    }
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
        if matches.count == 1 { return matches[0] }
        guard matches.isEmpty else { return nil }
        // A sentence the recorder split across two consecutive turns of the
        // same speaker ("We don't need to necessarily" / "grow our existing
        // team…") is still one verbatim passage; it belongs to the first.
        let spanning = sources.values.filter { turn in
            guard let next = sources[turn.id + 1], next.speaker == turn.speaker else { return false }
            return containsQuote(quote, in: turn.text + " " + next.text)
        }
        return spanning.count == 1 ? spanning[0] : nil
    }

    /// The turn plus its neighbours: a sentence that a chunk boundary split
    /// ("We don't need to necessarily" / "grow our existing team") is only
    /// whole when read across them.
    static func context(around source: MeetingSourceTurn, in sources: [Int: MeetingSourceTurn]) -> String {
        [sources[source.id - 1], source, sources[source.id + 1]].compactMap { $0 }
            .map { $0.speaker + " " + $0.text }.joined(separator: " ")
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
            let raw = MeetingSource.normalized(String(text[range]))
            let word = stem(raw)
            if tag == .noun, !generic.contains(word), forms(raw).isDisjoint(with: source) { supported = false }
            return supported
        }
        return supported
    }

    private static func stem(_ word: String) -> String {
        word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    /// Every spelling a word may take in the evidence: as written, its
    /// lemma, and singular/plural either way ("wins" ↔ "win").
    private static func forms(_ word: String) -> Set<String> {
        var result = lemmas(word)
        result.formUnion([word, stem(word), word + "s"])
        if word.count > 3, word.hasSuffix("s") { result.insert(String(word.dropLast())) }
        if word.hasSuffix("es"), word.count > 4 { result.insert(String(word.dropLast(2))) }
        return result
    }

    /// Staffing, money, commitments and people: a claim here must not
    /// introduce a verb the speaker never used ("commits", "eliminates").
    static let consequentialWords: Set<String> = ["invest", "investment", "investments", "commit", "commits", "committed", "commitment",
        "hire", "hiring", "headcount", "budget", "team", "teams", "eliminate", "cut", "reduce", "deadline", "money", "dollars",
        "cost", "costs", "fire", "promote", "layoff", "layoffs", "spend", "spending", "fund", "funding", "resource", "resources"]

    static func consequential(_ text: String) -> Bool {
        !Set(MeetingSource.words(text)).isDisjoint(with: consequentialWords)
    }

    static func verbsGrounded(_ text: String, in evidence: String) -> Bool {
        let source = lemmas(evidence)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var supported = true
        let auxiliary: Set<String> = ["be", "is", "are", "was", "were", "have", "has", "had", "do", "does", "did", "will", "would", "can", "could", "should", "may", "might", "get", "make", "say", "want", "need", "go", "propose", "suggest", "explain", "describe", "discuss", "mention", "note", "ask", "offer", "support", "agree", "raise"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard tag == .verb else { return true }
            let candidates = forms(MeetingSource.normalized(String(text[range])))
            if candidates.isDisjoint(with: auxiliary), candidates.isDisjoint(with: source) { supported = false }
            return supported
        }
        return supported
    }

    static let negations = [" not ", "n't", " never ", " no ", " without ", " avoid", " rather than ", " instead of ", " nor "]

    static func hasNegation(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        let spoken = " " + MeetingSource.normalized(text) + " "
        return negations.contains { lower.contains($0) } || spoken.contains(" don t ") || spoken.contains(" doesn t ")
            || spoken.contains(" won t ") || spoken.contains(" can t ") || spoken.contains(" shouldn t ") || spoken.contains(" isn t ")
    }

    /// A negated source must produce a negated claim. "We don't need to grow
    /// the team" summarized as "reduce the need for a team" flips meaning.
    static func negationPreserved(_ claim: String, quote: String) -> Bool {
        !hasNegation(quote) || hasNegation(claim)
    }

    static let decisionMarkers = ["let's ", "lets ", "we'll ", "we will ", "we're going to ", "we are going to ", "decided", "agreed", "we agree",
                                  "going with", "the plan is", "final answer", "sign off", "signed off", "approved"]
    static let pastMarkers = ["already", "we've ", "we have ", "have been", "has been", "invested", "committed", "we made", "we did", "last year", "last quarter"]
    static let tentativeMarkers = ["could ", "probably", "we should", "maybe", "might ", "i don't know", "i don t know", "not sure", "possibly", "perhaps", "i think we", "it would be nice", "one option", "we could"]

    /// The kind the evidence actually supports. The model's label is a hint;
    /// tense and hedging in the speaker's own words decide.
    static func supportedKind(_ proposed: MeetingClaimKind?, quote: String, claim: String) -> MeetingClaimKind {
        let lower = " " + quote.lowercased() + " "
        let isQuestion = quote.trimmingCharacters(in: .whitespaces).hasSuffix("?") || claim.trimmingCharacters(in: .whitespaces).hasSuffix("?")
        if isQuestion { return .openQuestion }
        let past = pastMarkers.contains { lower.contains($0) }
        let decided = decisionMarkers.contains { lower.contains($0) }
        let tentative = tentativeMarkers.contains { lower.contains($0) }
        switch proposed ?? .discussion {
        case .decision:
            if tentative { return .proposal }
            if past && !decided { return .existingCommitment }
            return decided ? .decision : .proposal
        case .existingCommitment:
            return past ? .existingCommitment : .discussion
        case .proposal:
            return .proposal
        case .openQuestion:
            return tentative ? .openQuestion : .discussion
        case .discussion:
            return past && consequential(claim) ? .existingCommitment : .discussion
        }
    }

    /// Greetings, agenda prompts and audio checks never lead a recap.
    static func isAgendaPrompt(_ text: String) -> Bool {
        let lower = MeetingSource.normalized(text)
        let patterns = ["what do you want to talk about", "what do you want to cover", "what s on your mind", "what s on the agenda", "agenda",
                        "how s it going", "how are you", "can you hear me", "can you see my screen", "let me share my screen", "good morning", "good afternoon",
                        "how was your weekend", "thanks for joining", "thanks for making time", "where do you want to start"]
        return patterns.contains { lower.contains($0) } || (MeetingSource.words(text).count <= 8 && text.contains("?"))
    }

    static func fact(_ candidate: MeetingFact, sources: [Int: MeetingSourceTurn]) -> MeetingFact? {
        factChecked(candidate, sources: sources).fact
    }

    /// Why a candidate was refused, for evaluation runs. Production reads
    /// only the fact.
    static func factChecked(_ candidate: MeetingFact, sources: [Int: MeetingSourceTurn]) -> (fact: MeetingFact?, rejection: String?) {
        guard legible(candidate.text), legible(candidate.quote) else { return (nil, "not legible") }
        guard let source = source(for: candidate.quote, in: sources) else { return (nil, "quote not found verbatim in exactly one turn") }
        guard candidate.text.count >= 12, candidate.text.count <= 650 else { return (nil, "length") }
        let evidence = context(around: source, in: sources)
        guard groundedWording(candidate.text, in: evidence) else { return (nil, "noun or number not in evidence") }
        guard negationPreserved(candidate.text, quote: candidate.quote) else { return (nil, "negation dropped") }
        if consequential(candidate.text) { guard verbsGrounded(candidate.text, in: evidence) else { return (nil, "consequential verb not in evidence") } }
        // Accept the model's natural tendency to start with the speaker,
        // but only if it agrees with this source. The renderer owns the label.
        var result = candidate
        result.sourceID = source.id
        let names = Set(sources.values.flatMap { MeetingSource.words($0.speaker) })
        let first = MeetingSource.words(result.text).first ?? ""
        if names.contains(first) {
            let allowed = [source.speaker, source.speaker.split(separator: " ").first.map(String.init) ?? source.speaker]
            guard let name = allowed.first(where: { result.text.lowercased().hasPrefix($0.lowercased() + " ") }) else { return (nil, "starts with another speaker's name") }
            let rest = result.text.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            result.text = rest.prefix(1).uppercased() + rest.dropFirst()
        } else if ["he", "she", "they", "you"].contains(first) { return (nil, "starts with a pronoun") }
        guard MeetingSource.words(result.text).count >= 4 else { return (nil, "too short") }
        result.kind = supportedKind(candidate.kind, quote: candidate.quote, claim: result.text)
        if result.resolvedKind == .openQuestion || isAgendaPrompt(candidate.quote) { result.importance = min(result.importance, 1) }
        return (result, nil)
    }

    static let commitmentPhrases = ["i will ", "i ll ", "i am going to ", "i m going to ", "let me ", "i can send ", "i can share ", "i can introduce ",
                                    "i can bring ", "i can talk ", "i ll talk ", "i can look ", "i can identify ", "i can go ", "i can put ", "i can set ",
                                    "i can reach ", "i can write ", "i can draft ", "i can pull ", "i can get ", "i can check ", "i can follow ", "i can map "]
    static let tentativePhrases = ["we should ", "we need to ", "someone should ", "somebody should ", "we ought to ", "we have to ", "it would be good to ", "we could "]

    /// Does this turn contain wording that can carry a follow-up?
    static func mentionsFollowUp(_ text: String) -> Bool {
        let spoken = " " + MeetingSource.normalized(text) + " "
        let request = ["can you ", "could you ", "would you "]
        return (commitmentPhrases + tentativePhrases + request).contains { spoken.contains(" " + $0) }
    }

    /// The sentence of a turn that carries the promise, request or shared
    /// intention, if any.
    static func followUpSentence(in text: String) -> String? {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var found: String?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if mentionsFollowUp(sentence) { found = sentence; return false }
            return true
        }
        return found
    }

    /// A small model often quotes the sentence NEXT to the promise. The turn
    /// it named is verified evidence, so anchor the quote to that turn's own
    /// promise sentence before judging the candidate.
    static func repairQuote(_ candidate: MeetingCommitment, sources: [Int: MeetingSourceTurn]) -> MeetingCommitment {
        guard let turn = sources[candidate.sourceID], !mentionsFollowUp(candidate.quote) || source(for: candidate.quote, in: sources) == nil,
              let sentence = followUpSentence(in: turn.text) else { return candidate }
        var repaired = candidate
        repaired.quote = sentence
        return repaired
    }

    /// A follow-up read straight off the speaker's words, for a turn the
    /// model skipped: "I can identify five or six broken workflows" becomes
    /// Identify five or six broken workflows, owned by its speaker; "we
    /// should run a showcase" becomes an unassigned suggestion. Verbatim
    /// words only, so nothing can be invented.
    static func literalFollowUp(in turn: MeetingSourceTurn) -> MeetingCommitment? {
        guard !turn.timestamp.isEmpty, !MeetingSource.genericSpeaker(turn.speaker), let sentence = followUpSentence(in: turn.text) else { return nil }
        let spoken = " " + MeetingSource.normalized(sentence) + " "
        let owned = commitmentPhrases.first { spoken.contains(" " + $0) }
        let shared = tentativePhrases.first { spoken.contains(" " + $0) }
        guard owned != nil || shared != nil else { return nil }
        // Keep the speaker's own tokens (names, hyphens); drop the leading
        // modal words so the task starts at the verb.
        let modal: Set<String> = ["i", "ill", "will", "can", "am", "m", "going", "to", "let", "me", "we", "should", "need", "someone", "somebody",
                                  "ought", "have", "it", "would", "be", "good", "could", "just", "also", "probably", "definitely", "then", "so"]
        var tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        // Start at the phrase itself when it does not open the sentence.
        let normalizedTokens = tokens.map { MeetingSource.normalized($0) }
        let phraseFirst = MeetingSource.words(owned ?? shared!).first ?? ""
        if let at = normalizedTokens.firstIndex(of: phraseFirst) { tokens = Array(tokens[at...]) }
        var stripped = 0
        while let first = tokens.first, stripped < 5, modal.contains(MeetingSource.normalized(first)) { tokens.removeFirst(); stripped += 1 }
        // "let me know" is not a deliverable; "I can bring that up" is.
        if MeetingSource.normalized(tokens.first ?? "") == "know" { return nil }
        if let stop = tokens.firstIndex(where: { ["and", "but", "so", "because", "which"].contains(MeetingSource.normalized($0)) }), stop >= 3 { tokens = Array(tokens[..<stop]) }
        guard tokens.count >= 2 else { return nil }
        tokens[tokens.count - 1] = tokens[tokens.count - 1].trimmingCharacters(in: .punctuationCharacters)
        let task = tokens[0].prefix(1).uppercased() + tokens[0].dropFirst() + " " + tokens.dropFirst().joined(separator: " ")
        guard isTaskTitle(task) else { return nil }
        let candidate = MeetingCommitment(sourceID: turn.id, owner: owned != nil ? turn.speaker : MeetingCommitment.unassignedOwner,
                                          task: task, quote: sentence, due: "", confidence: 0.9, tentative: owned == nil)
        return commitment(candidate, sources: [turn.id: turn])
    }

    static func commitment(_ candidate: MeetingCommitment, sources: [Int: MeetingSourceTurn]) -> MeetingCommitment? {
        let candidate = repairQuote(candidate, sources: sources)
        guard legible(candidate.quote), legible(candidate.task),
              candidate.confidence >= 0.5, let source = source(for: candidate.quote, in: sources),
              !source.timestamp.isEmpty, containsQuote(candidate.quote, in: source.text),
              isTaskTitle(candidate.task), groundedWording(candidate.task, in: context(around: source, in: sources)) else { return nil }
        var result = candidate
        result.sourceID = source.id
        let quote = MeetingSource.normalized(candidate.quote)
        let hypothetical = ["i should", "you should", "i might", "i would", "if i", "if we", "i want to be", "i am a", "i m a", "i m still", "going to consider", "need to think",
                            "one day", "someday", "some day", "eventually", "at some point", "down the road", "in the future", "haven t decided", "have not decided"]
        guard !hypothetical.contains(where: quote.contains) else { return nil }
        let shared = tentativePhrases.contains(where: quote.contains)
        if candidate.tentative == true || candidate.owner == MeetingCommitment.unassignedOwner || (MeetingSource.genericSpeaker(candidate.owner) && shared) {
            // Worth returning to, but nobody owns it yet. Never a task.
            guard shared else { return nil }
            result.owner = MeetingCommitment.unassignedOwner
            result.tentative = true
            result.isRequest = false
            result.due = ""
            return result
        }
        guard !MeetingSource.genericSpeaker(candidate.owner) else { return nil }
        if candidate.owner == source.speaker {
            guard commitmentPhrases.contains(where: quote.contains) else {
                // "We should…" with a named owner: keep the follow-up, lose
                // the invented ownership.
                guard shared else { return nil }
                result.owner = MeetingCommitment.unassignedOwner
                result.tentative = true
                result.isRequest = false
                result.due = ""
                return result
            }
            result.isRequest = false
        } else {
            let others = Set(sources.values.map(\.speaker)).subtracting([source.speaker])
                .filter { !MeetingSource.genericSpeaker($0) }
            let request = ["can you ", "could you ", "would you ", "would you be able to "]
            guard request.contains(where: quote.contains), others.contains(candidate.owner),
                  others.count == 1 || quote.contains(MeetingSource.normalized(candidate.owner)) else { return nil }
            result.isRequest = true
        }
        result.tentative = false
        if !candidate.due.isEmpty, !quote.contains(MeetingSource.normalized(candidate.due)) || !DueDate.isTemporalExpression(candidate.due)
            || DueDate.isDuration(candidate.due) { result.due = "" }
        return result
    }

    static func isTaskTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["\"", "“", "'"].contains(where: trimmed.hasPrefix) else { return false }
        let words = MeetingSource.words(trimmed)
        let verbs: Set<String> = ["send", "share", "review", "introduce", "simplify", "instrument", "add", "fix", "schedule", "update", "write", "check", "prepare", "submit", "follow", "book", "create", "remove", "test", "contact", "email", "call", "confirm", "publish", "deploy", "resend", "grant", "provide", "set", "build", "implement", "investigate", "finish", "deliver", "complete", "invite", "connect", "upload", "read", "compare", "design", "document", "measure", "track", "audit", "launch", "move", "resolve", "plan", "ask", "collect", "export", "arrange", "bring", "raise", "talk", "identify", "map", "propose", "discuss", "draft", "pull", "look", "reach", "put", "find", "list", "gather", "align", "sync", "meet", "present", "walk", "clarify", "define", "scope", "estimate", "outline", "ship", "explore", "evaluate", "pilot", "run", "start", "kick", "loop", "circle", "coordinate", "secure", "get"]
        return (2...20).contains(words.count) && verbs.contains(words[0])
            && words.dropFirst().contains { !["it", "this", "that", "them", "the", "a", "to", "with", "up", "information", "stuff", "thing", "things", "something", "anything", "everything", "details", "work"].contains($0) }
    }
}

enum GroundedMeetingNotes {
    static func generate(_ meeting: Meeting, corrections: [String: String] = [:], useLanguageModel: Bool = true,
                         progress: @escaping MeetingNotesService.Progress = { _ in }) async -> MeetingAnalysis {
        let cacheURL = MeetingNotesCache.url(for: meeting)
        let parsed = MeetingSource.parse(meeting.transcript)
        let publicSource = MeetingSource.publicTurns(parsed)
        let omitted = publicSource.count < parsed.filter { !MeetingSource.isBackchannel($0.text) }.count
        // Spellings the meeting itself establishes (a phrase said clearly
        // several times) repair its one-off near-misses. Derived input only;
        // the transcript keeps the recognizer's words, and every change is
        // recorded at the end of the notes.
        let aliases = corrections
        let vocabulary = DictationCleanup.userVocabulary()
        let prepared = publicSource.map { turn -> MeetingSourceTurn in
            let fixed = MeetingVocabulary.correct(turn.text, terms: vocabulary, aliases: aliases)
            return MeetingSourceTurn(id: turn.id, speaker: turn.speaker == "You" ? meeting.resolvedOwner : turn.speaker,
                                     timestamp: turn.timestamp, text: fixed.text)
        }
        let sources = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0) })
        var facts: [MeetingFact] = []; var actions: [MeetingCommitment] = []
        var unclear = 0
        let debug = ProcessInfo.processInfo.environment["MAN_NOTES_DEBUG"] == "1"
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useLanguageModel, case .available = SystemLanguageModel.default.availability {
            // Smaller windows: the model returns a handful of facts per call,
            // so a 30-minute meeting read in five bites came back as five
            // bullets. More, shorter reads cover the whole conversation.
            var modelResponsive = true
            let windows = MeetingSource.windows(prepared, limit: 2600)
            for (index, window) in windows.enumerated() {
                guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
                await progress("Reading sources · \(index + 1) of \(windows.count)…")
                let cacheKey = "sources-v1:" + meeting.kind + ":" + window
                if let cached = await MeetingNotesCache.shared.value(for: cacheKey, at: cacheURL) {
                    facts += cached.facts; actions += cached.actions; unclear += cached.unclear
                    continue
                }
                guard modelResponsive else {
                    facts += fallbackFacts(prepared.filter { window.contains("[T\($0.id)]") }).sorted { $0.quote.count > $1.quote.count }.prefix(1)
                    continue
                }
                let factStart = facts.count, actionStart = actions.count, unclearStart = unclear
                let session = LanguageModelSession(instructions: instructions(listening: meeting.captureKind == .listening))
                do {
                    let response = try await AsyncDeadline.run(seconds: 20) {
                        (try await session.respond(to: window, generating: Extraction.self)).content
                    }
                    facts += response.facts.filter { $0.importance >= 2 }.compactMap {
                        let candidate = MeetingFact(sourceID: $0.sourceID, text: $0.text, quote: $0.quote, importance: $0.importance,
                                                    kind: MeetingClaimKind(rawValue: $0.kind))
                        let checked = MeetingEvidence.factChecked(candidate, sources: sources)
                        if debug { print("NOTES_DEBUG fact \(checked.rejection ?? "ACCEPTED as \(checked.fact!.resolvedKind.rawValue)") | \(candidate.kind?.rawValue ?? "?") | \(candidate.text) | «\(candidate.quote)»") }
                        if let fact = checked.fact { return fact }
                        // Keep the model-selected evidence if its paraphrase is
                        // unsupported. Never substitute an unrelated paragraph,
                        // and never quote a passage that is not readable.
                        guard let source = MeetingEvidence.source(for: $0.quote, in: sources),
                              (60...450).contains($0.quote.count) else { return nil }
                        guard MeetingEvidence.legible($0.quote) else { unclear += 1; return nil }
                        return MeetingFact(sourceID: source.id, text: "“\($0.quote)”", quote: $0.quote, importance: 1, kind: .discussion)
                    }
                    if meeting.captureKind != .listening {
                        actions += response.commitments.compactMap {
                            let candidate = MeetingCommitment(sourceID: $0.sourceID, owner: $0.owner, task: $0.task,
                                                              quote: $0.quote, due: $0.due, confidence: $0.confidence, tentative: $0.tentative)
                            let accepted = MeetingEvidence.commitment(candidate, sources: sources)
                            if debug { print("NOTES_DEBUG action \(accepted == nil ? "REJECTED" : "ACCEPTED") | \($0.owner) | tentative=\($0.tentative) conf=\($0.confidence) | \($0.task) | «\($0.quote)» due=\($0.due)") }
                            return accepted
                        }
                    }
                    await MeetingNotesCache.shared.save(.init(facts: Array(facts.dropFirst(factStart)),
                        actions: Array(actions.dropFirst(actionStart)), unclear: unclear - unclearStart),
                        source: cacheKey, at: cacheURL)
                } catch {
                    if error is AsyncDeadline.TimedOut { modelResponsive = false }
                    // Keep this window represented by an attributed source
                    // excerpt, rather than silently dropping part of the recording.
                    if debug { print("NOTES_DEBUG fact pass failed: \(error)") }
                    Analytics.track("meeting_grounding_window_failed", ["window": index, "of": windows.count])
                    facts += fallbackFacts(prepared.filter { window.contains("[T\($0.id)]") }).sorted { $0.quote.count > $1.quote.count }.prefix(1)
                }
            }
            // Follow-ups get their own read, one promise-bearing turn at a
            // time. Asked for a whole window at once the model lists two or
            // three and stops; asked about the turn that literally says
            // "I can…" or "we should…" it answers every time. The validators
            // still decide what survives.
            if meeting.captureKind != .listening {
                let candidates = prepared.filter { MeetingEvidence.mentionsFollowUp($0.text) }.prefix(24)
                for (index, turn) in candidates.enumerated() {
                    guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
                    await progress("Collecting follow-ups · \(index + 1) of \(candidates.count)…")
                    let excerpt = [sources[turn.id - 1], turn, sources[turn.id + 1]].compactMap { $0?.prompt }.joined(separator: "\n\n")
                    let cacheKey = "followup-v1:" + excerpt + " target:" + String(turn.id)
                    if let cached = await MeetingNotesCache.shared.value(for: cacheKey, at: cacheURL) {
                        actions += cached.actions
                        continue
                    }
                    guard modelResponsive else {
                        if let literal = MeetingEvidence.literalFollowUp(in: turn) { actions.append(literal) }
                        continue
                    }
                    let session = LanguageModelSession(instructions: followUpInstructions)
                    var found: [MeetingCommitment] = []
                    var succeeded = false
                    let actionStart = actions.count
                    do {
                        let response = try await AsyncDeadline.run(seconds: 20) {
                            (try await session.respond(to: excerpt + "\n\nReport the follow-up in [T\(turn.id)] if there is one.", generating: FollowUpExtraction.self)).content
                        }
                        succeeded = true
                        found = response.commitments.compactMap {
                            let candidate = MeetingCommitment(sourceID: $0.sourceID, owner: $0.owner, task: $0.task,
                                                              quote: $0.quote, due: $0.due, confidence: $0.confidence, tentative: $0.tentative)
                            let accepted = MeetingEvidence.commitment(candidate, sources: sources)
                            if debug { print("NOTES_DEBUG followup \(accepted == nil ? "REJECTED" : "ACCEPTED") | \($0.owner) | tentative=\($0.tentative) conf=\($0.confidence) | \($0.task) | «\($0.quote)»") }
                            return accepted
                        }
                    } catch {
                        if error is AsyncDeadline.TimedOut { modelResponsive = false }
                        if debug { print("NOTES_DEBUG followup pass failed: \(error)") }
                        Analytics.track("meeting_followup_turn_failed", ["turn": turn.id])
                    }
                    if found.contains(where: { $0.sourceID == turn.id }) {
                        actions += found
                    } else if let literal = MeetingEvidence.literalFollowUp(in: turn) {
                        // The model skipped or misquoted it; the speaker's own
                        // sentence is the follow-up.
                        if debug { print("NOTES_DEBUG followup LITERAL | \(literal.owner) | \(literal.task) | «\(literal.quote)»") }
                        actions += found + [literal]
                    } else {
                        actions += found
                    }
                    if succeeded {
                        await MeetingNotesCache.shared.save(.init(facts: [], actions: Array(actions.dropFirst(actionStart)), unclear: 0),
                                                            source: cacheKey, at: cacheURL)
                    }
                }
            }
        }
        #endif
        guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
        if !useLanguageModel {
            // A deadline must not discard successfully grounded earlier windows.
            for window in MeetingSource.windows(prepared, limit: 2600) {
                let key = "sources-v1:" + meeting.kind + ":" + window
                if let cached = await MeetingNotesCache.shared.value(for: key, at: cacheURL) {
                    facts += cached.facts; actions += cached.actions; unclear += cached.unclear
                } else { facts += fallbackFacts(prepared.filter { window.contains("[T\($0.id)]") }) }
            }
            actions += prepared.compactMap { MeetingEvidence.literalFollowUp(in: $0) }
        }
        if facts.isEmpty {
            let fallback = fallbackFacts(prepared)
            facts = fallback.filter { MeetingEvidence.legible($0.quote) }
            unclear += fallback.count - facts.count
        }
        actions = selectActions(actions)
        // A promise is a follow-up, not also a topic.
        let promised = Set(actions.map { MeetingSource.normalized($0.quote) })
        let selected = selectFacts(facts.filter { fact in
            !promised.contains { $0.contains(MeetingSource.normalized(fact.quote)) || MeetingSource.normalized(fact.quote).contains($0) }
        })
        var overview = ""
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useLanguageModel, meeting.captureKind != .listening, !selected.isEmpty,
           case .available = SystemLanguageModel.default.availability {
            await progress("Writing overview…")
            overview = (try? await AsyncDeadline.run(seconds: 20) {
                await self.overview(from: selected, sources: sources)
            }) ?? ""
        }
        #endif
        let markdown = render(facts: selected, actions: actions, sources: sources, meeting: meeting, privateOmitted: omitted,
                              unclear: unclear, overview: overview)
        let audit = publicSource.flatMap { MeetingVocabulary.correct($0.text, terms: vocabulary, aliases: aliases).corrections }
        let suffix = Array(Set(audit)).sorted().map { "<!-- corrected: \($0.replacingOccurrences(of: "--", with: "—")) -->" }.joined(separator: "\n")
        return MeetingAnalysis(markdown: markdown + (suffix.isEmpty ? "" : "\n\n" + suffix), facts: selected,
                               actions: actions, omittedPrivatePassages: omitted, unclearPassages: unclear)
    }

    /// Distinct facts, spread across the whole conversation so the closing
    /// minutes get the same chance as the opening ones.
    static func selectFacts(_ facts: [MeetingFact]) -> [MeetingFact] {
        var kept: [MeetingFact] = []
        for fact in facts.sorted(by: { $0.sourceID < $1.sourceID }) {
            // Two notes citing the same passage are one note. Similar
            // paraphrases of DIFFERENT passages are both kept.
            let words = Set(MeetingSource.words(fact.quote))
            let duplicate = kept.contains { other in
                let otherWords = Set(MeetingSource.words(other.quote))
                let overlap = Double(words.intersection(otherWords).count) / Double(max(1, min(words.count, otherWords.count)))
                return MeetingSource.normalized(other.text) == MeetingSource.normalized(fact.text) || overlap >= 0.8
            }
            if !duplicate { kept.append(fact) }
        }
        guard kept.count > 12 else { return kept }
        // Preserve coverage across the whole conversation, not just its opening.
        return (0..<12).compactMap { bucket in
            let start = bucket * kept.count / 12, end = (bucket + 1) * kept.count / 12
            return kept[start..<end].max {
                ($0.importance, MeetingNoteSections.salience($0.quote)) < ($1.importance, MeetingNoteSections.salience($1.quote))
            }
        }
    }

    /// Follow-ups from the whole meeting: owned ones first, then the shared
    /// "we should"s, in the order they came up — never trimmed to a quota.
    static func selectActions(_ actions: [MeetingCommitment]) -> [MeetingCommitment] {
        var seen = Set<String>()
        var turns = Set<String>()
        // The same promise read twice is one follow-up: one owner per turn,
        // keeping the fuller wording.
        let unique = actions.sorted { ($0.task.count, $0.confidence) > ($1.task.count, $1.confidence) }
            .filter { seen.insert($0.key).inserted && turns.insert("\($0.sourceID)|\($0.owner)").inserted }
        let owned = unique.filter { $0.tentative != true }.sorted { $0.sourceID < $1.sourceID }
        let tentative = unique.filter { $0.tentative == true }.sorted { $0.sourceID < $1.sourceID }
        return Array(owned.prefix(10)) + Array(tentative.prefix(6))
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
            guard let quote = sentences.filter({ MeetingNoteSections.isSubstantive($0) }).max(by: { score($0) + MeetingNoteSections.salience($0) < score($1) + MeetingNoteSections.salience($1) }), score(quote) >= 4,
                  !MeetingEvidence.isAgendaPrompt(quote) else { return nil }
            return MeetingFact(sourceID: turn.id, text: "“\(quote)”", quote: quote, importance: 1, kind: .discussion)
        }
    }

    /// Facts worth opening with: substantive, not questions or agenda talk.
    static func leadFacts(_ facts: [MeetingFact], limit: Int = 3) -> [MeetingFact] {
        let substantive = facts.filter { $0.resolvedKind != .openQuestion && !MeetingEvidence.isAgendaPrompt($0.quote) && !$0.text.hasPrefix("“") }
        let ranked = substantive.sorted { ($0.importance, -$0.sourceID) > ($1.importance, -$1.sourceID) }
        return Array(ranked.prefix(limit)).sorted { $0.sourceID < $1.sourceID }
    }

    #if canImport(FoundationModels)
    /// Two or three sentences over the selected facts only. Every sentence
    /// must stay inside the facts' own words; otherwise the facts speak for
    /// themselves.
    @available(macOS 26.0, *)
    static func overview(from facts: [MeetingFact], sources: [Int: MeetingSourceTurn]) async -> String {
        let lead = leadFacts(facts, limit: 6)
        guard !lead.isEmpty else { return "" }
        let material = lead.map { fact -> String in
            let speaker = sources[fact.sourceID]?.speaker ?? "Speaker"
            return "- \(speaker) (\(fact.resolvedKind.rawValue.replacingOccurrences(of: "_", with: " "))): \(fact.text)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            Write a two or three sentence overview of a meeting using ONLY the notes provided. Keep each note's tense, hedging and negation exactly (a proposal stays a proposal; "don't need to grow" must not become "reduce"). Name who said what only as the notes do. Do not add facts, names, numbers, products, outcomes or dates that are not in the notes. Plain prose, no bullets, no preamble.
            """)
        guard let response = try? await session.respond(to: material) else { return "" }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = lead.map { $0.text + " " + $0.quote + " " + (sources[$0.sourceID]?.speaker ?? "") }.joined(separator: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)); return true
        }
        guard (1...4).contains(sentences.count),
              sentences.allSatisfy({ MeetingEvidence.groundedWording($0, in: evidence) && MeetingEvidence.legible($0) }),
              !lead.contains(where: { MeetingEvidence.hasNegation($0.text) }) || MeetingEvidence.hasNegation(text) else { return "" }
        return sentences.joined(separator: " ")
    }
    #endif

    static func render(facts: [MeetingFact], actions: [MeetingCommitment], sources: [Int: MeetingSourceTurn],
                       meeting: Meeting, privateOmitted: Bool, unclear: Int = 0, overview: String = "") -> String {
        func stamp(_ source: MeetingSourceTurn) -> String {
            guard !source.timestamp.isEmpty else { return "(time unavailable)" }
            let next = sources.values.filter { $0.seconds > source.seconds }.min { $0.seconds < $1.seconds }
            return "[" + source.timestamp + (next.map { "–" + $0.timestamp } ?? "") + "]"
        }
        func line(_ fact: MeetingFact) -> String {
            guard let source = sources[fact.sourceID] else { return "" }
            return "- \(source.speaker): \(fact.text) \(stamp(source))"
        }
        var output: String
        if meeting.captureKind == .listening {
            output = "## Takeaways\n\n" + facts.map(line).joined(separator: "\n")
        } else {
            var lead = leadFacts(facts)
            if lead.isEmpty { lead = Array(facts.sorted { ($0.importance, -$0.sourceID) > ($1.importance, -$1.sourceID) }.prefix(3)).sorted { $0.sourceID < $1.sourceID } }
            output = "## Overview\n\n" + (overview.isEmpty ? lead.prefix(3).map { fact in var brief = fact; brief.text = MeetingNoteSections.sentences(fact.text).first ?? fact.text; return line(brief) }.joined(separator: "\n") : MeetingNoteSections.sentences(overview).prefix(3).joined(separator: " "))
            let topics = facts.filter { $0.resolvedKind == .discussion }
            if !topics.isEmpty { output += "\n\n## Main topics\n\n" + topics.map(line).joined(separator: "\n") }
            let existing = facts.filter { $0.resolvedKind == .existingCommitment }
            let proposals = facts.filter { $0.resolvedKind == .proposal }
            let decisions = facts.filter { $0.resolvedKind == .decision }
            if !existing.isEmpty || !proposals.isEmpty || !decisions.isEmpty {
                output += "\n\n## Decisions and alignment\n"
                if !existing.isEmpty { output += "\n*Already committed*\n" + existing.map(line).joined(separator: "\n") + "\n" }
                if !proposals.isEmpty { output += "\n*Proposed, not decided*\n" + proposals.map(line).joined(separator: "\n") + "\n" }
                if !decisions.isEmpty { output += "\n*Decided*\n" + decisions.map(line).joined(separator: "\n") + "\n" }
                output = output.trimmingCharacters(in: .newlines)
            }
            if !actions.isEmpty {
                output += "\n\n## Next steps\n\n" + actions.compactMap { action -> String? in
                    guard let source = sources[action.sourceID] else { return nil }
                    var line = action.tentative == true
                        ? "- \(MeetingCommitment.unassignedOwner) — \(action.task) (suggested)"
                        : "- **\(action.owner)** — \(action.task)"
                    if action.isRequest { line += " (requested)" }
                    if !action.due.isEmpty { line += " — due \(DueDate.resolve(action.due, from: meeting.startedAt) ?? action.due)" }
                    else { line += " — date not agreed" }
                    return line + " " + stamp(source)
                }.joined(separator: "\n")
            }
            if actions.isEmpty { output += "\n\n## Next steps\n\nNone agreed. Owner: none assigned. Date: none agreed." }
            output += "\n\n" + MeetingNoteSections.quotes(meeting: meeting)
            output += MeetingNoteSections.interview(meeting: meeting)
            let questions = facts.filter { $0.resolvedKind == .openQuestion }
            if !questions.isEmpty { output += "\n\n## Open questions\n\n" + questions.map(line).joined(separator: "\n") }
        }
        if privateOmitted { output += "\n\n*Private passages omitted from these notes.*" }
        if unclear > 0 { output += "\n\n*\(unclear) unclear passage\(unclear == 1 ? " was" : "s were") left out of these notes. The transcript has the original words.*" }
        return output
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *) private static func instructions(listening: Bool) -> String {
        """
        Read these source turns and extract grounded \(listening ? "takeaways from a recording the owner listened to" : "meeting notes"). Each starts with [Tnumber], a speaker, and a timestamp.
        Return zero to six useful facts worth remembering later: concrete proposals, explanations, decisions, numbers, and outcomes. Cover the later material too. Ignore greetings, filler, agenda prompts, calendar chit-chat, and audio checks. Return an empty facts array for small talk. A useful note states the actual proposal or explanation, not merely that somebody discussed a topic. Every fact needs its exact sourceID and a short VERBATIM quote from THAT turn. Use the speaker's concrete words; do not invent jargon, names, numbers, versions, technology (bots are not robotics), causality, or commitments. Keep the speaker's tense, hedging and negation: "we don't need to grow the team" is NOT "reduce the team"; something already invested in is an existing commitment, not a new decision; "could", "probably", "we should" and "I don't know" are tentative. The app supplies speaker attribution: write the fact without a leading name or pronoun. A speaker reporting somebody else's idea is not proposing it themselves. Predictions and statements about other companies are that speaker's opinion. importance is 1–3, with decisions/proposals at 3. kind is one of: discussion, proposal, existing_commitment, decision, open_question.
        \(listening ? "This is passive listening, not the owner's meeting. commitments MUST be an empty list. Advice and examples are takeaways, never tasks." : "Commitments are explicit first-person promises (I'll, I will, let me, I can bring/talk/identify) or clear requests to a known participant for a concrete deliverable, from anywhere in the meeting including its final minutes. Opinions, aspirations, things already done, and personal schedules are NOT actions. A shared 'we should' or 'we need to' is a tentative follow-up: set tentative true and owner to the exact text Owner not assigned. Never create an action for an unnamed Speaker. owner must be an exact supplied speaker label or Owner not assigned; sourceID must identify the person making the promise or request. Each quote must contain the explicit commitment/request verbatim. Paraphrase task as an imperative verb plus a specific object (e.g. Send the deck links); never output a quoted first-person sentence. Copy due words exactly from that SAME quote or leave empty; a duration like month-long is not a due date. confidence is 0 to 1; only explicit, unambiguous evidence merits >= 0.85. Do not pad the list.")
        """
    }

    @available(macOS 26.0, *) private static var followUpInstructions: String {
        """
        Read these source turns (each starts with [Tnumber], a speaker, and a timestamp) and report the follow-up in the indicated turn; the neighbours are context only. A follow-up is: an explicit first-person promise (I'll, I will, let me, I can bring/talk/identify/send/share/look); a direct request to a named participant (can you, could you, would you); or a shared intention with no owner (we should, we need to, someone should). Return an empty list only if there are none. For each: sourceID of the turn; quote = the exact sentence containing the promise, request or we-should, copied verbatim; owner = that speaker's exact label for a promise, the named recipient for a request, or the exact text Owner not assigned for a shared we-should (set tentative true); task = imperative verb plus specific object using the speaker's words; due = deadline words copied from the same sentence, empty if none — a duration like month-long is not a deadline; confidence 0 to 1. Never invent names, owners, dates, or tasks that were not said.
        """
    }

    @available(macOS 26.0, *) @Generable fileprivate struct FollowUpExtraction: Sendable {
        @Guide(description: "The promise, request, or shared we-should in the indicated turn; empty if it holds none.", .count(0...2)) var commitments: [ExtractedCommitment]
    }

    @available(macOS 26.0, *) @Generable fileprivate struct ExtractedFact: Sendable {
        @Guide(description: "The integer after T in the source label, e.g. 12 from [T12].") var sourceID: Int
        @Guide(description: "Copy 4 to 20 consecutive words EXACTLY from this source utterance, including filler. Spoken content, never a speaker name.") var quote: String
        @Guide(description: "State the actual point using the source’s concrete words and tense, e.g. The registration report should be delivered by email. Keep any negation. Do not start with a speaker name. Do not say that somebody discussed a topic; explain the point.") var text: String
        @Guide(description: "1 for background, 2 for explanation, 3 for a specific proposal or decision.", .range(1...3)) var importance: Int
        @Guide(description: "discussion, proposal, existing_commitment (already done or invested in), decision (explicitly agreed now), or open_question.") var kind: String
    }
    @available(macOS 26.0, *) @Generable fileprivate struct ExtractedCommitment: Sendable {
        @Guide(description: "The integer after T in the turn containing the explicit promise or request.") var sourceID: Int
        @Guide(description: "Copy the exact sentence containing I'll, I will, I can, let me, we should, or can you AND its deliverable. Never a speaker name.") var quote: String
        @Guide(description: "The exact speaker promising this work, the named recipient of the direct request, or Owner not assigned for a shared we-should.") var owner: String
        @Guide(description: "Imperative verb plus specific object, paraphrasing that promise. Omit advice, suggestions, and already completed work.") var task: String
        @Guide(description: "Deadline words copied from that same sentence, or empty if unstated. Durations are not deadlines.") var due: String
        @Guide(description: "Certainty that this is an explicit deliverable promised by this owner, or a clear shared follow-up.", .range(0.0...1.0)) var confidence: Double
        @Guide(description: "true only for a shared we-should / we-need-to with no named owner.") var tentative: Bool
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Extraction: Sendable {
        @Guide(description: "Useful facts backed by exact quoted source evidence.", .count(0...6)) var facts: [ExtractedFact]
        @Guide(description: "Explicit promises, direct requests, and shared follow-ups only. Empty when nobody commits to new work.", .count(0...4)) var commitments: [ExtractedCommitment]
    }
    #endif
}
