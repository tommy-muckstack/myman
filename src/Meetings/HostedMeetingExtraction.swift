import Foundation

/// What the hosted writing model returns for a whole transcript (or one of
/// at most three chunks). The shape mirrors the on-device `Extraction`; every
/// candidate still passes through `MeetingEvidence` before it becomes a note.
struct HostedExtraction: Codable, Sendable {
    struct Fact: Codable, Sendable {
        var sourceID: Int
        var quote: String
        var text: String
        var importance: Int
        var kind: String
    }
    struct Commitment: Codable, Sendable {
        var sourceID: Int
        var quote: String
        var owner: String
        var task: String
        var due: String
        var confidence: Double
        var tentative: Bool
    }
    var facts: [Fact]
    var commitments: [Commitment]
    var overview: String

    /// Strict JSON Schema: every object closed, every property required, no
    /// min/max (importance and confidence are clamped in Swift). The kind
    /// enum matches `MeetingClaimKind` raw values exactly.
    static let schema = """
    {"type":"object","additionalProperties":false,"required":["facts","commitments","overview"],"properties":{"facts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["sourceID","quote","text","importance","kind"],"properties":{"sourceID":{"type":"integer","description":"The integer after T in the source label, e.g. 12 from [T12]."},"quote":{"type":"string","description":"4 to 20 consecutive words copied EXACTLY from that turn, including filler. Spoken content, never a speaker name."},"text":{"type":"string","description":"The actual point in the source's concrete words and tense. Keep any negation. Do not start with a speaker name."},"importance":{"type":"integer","description":"1 for background, 2 for explanation, 3 for a specific proposal or decision."},"kind":{"type":"string","enum":["discussion","proposal","existing_commitment","decision","open_question"]}}}},"commitments":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["sourceID","quote","owner","task","due","confidence","tentative"],"properties":{"sourceID":{"type":"integer","description":"The integer after T in the turn containing the explicit promise or request."},"quote":{"type":"string","description":"The exact sentence containing I'll, I will, I can, let me, we should, or can you AND its deliverable."},"owner":{"type":"string","description":"The exact speaker label promising this work, the named recipient of a direct request, or Owner not assigned for a shared we-should."},"task":{"type":"string","description":"Imperative verb plus specific object, paraphrasing that promise."},"due":{"type":"string","description":"Deadline words copied from that same sentence, or empty. Durations are not deadlines."},"confidence":{"type":"number","description":"0 to 1."},"tentative":{"type":"boolean","description":"true only for a shared we-should / we-need-to with no named owner."}}}},"overview":{"type":"string","description":"Two or three plain sentences using only the facts listed, keeping their tense, hedging and negation. Empty for small talk."}}}
    """

    /// The on-device fact and follow-up instructions, merged, plus what a
    /// whole-transcript reader can do that a 2,600-character window cannot.
    static func instructions(listening: Bool) -> String {
        GroundedMeetingNotes.instructions(listening: listening) + "\n\n"
            + GroundedMeetingNotes.followUpInstructions.replacingOccurrences(of: "report the follow-up in the indicated turn; the neighbours are context only", with: "report every follow-up anywhere in them") + "\n\n"
            + """
            You receive the WHOLE transcript (or a large part of it) rather than a short window. Return up to 40 facts spread across the entire conversation, including its final minutes, and every explicit follow-up. \
            overview: two or three plain sentences using ONLY the facts you listed. Keep each fact's tense, hedging and negation exactly (a proposal stays a proposal; "don't need to grow" must not become "reduce"). Do not add names, numbers, products, outcomes or dates that are not in your facts. Empty string for small talk. \
            Return JSON matching the schema and nothing else.
            """
    }

    static func decode(_ text: String) throws -> HostedExtraction {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do { return try JSONDecoder().decode(HostedExtraction.self, from: Data(body.utf8)) }
        catch { throw WritingModelError.decode("extraction JSON") }
    }
}

enum HostedMeetingNotes {
    struct Result: Sendable {
        var facts: [MeetingFact] = []
        var actions: [MeetingCommitment] = []
        var unclear = 0
        var overview = ""
        var chunks = 0
        var inputTokens = 0
        var outputTokens = 0
        var transcriptChars = 0
    }

    /// Characters of prepared transcript sent in a single request before the
    /// transcript is split into at most three chunks.
    static let singleRequestLimit = 120_000

    static func chunks(_ prepared: [MeetingSourceTurn]) -> [String] {
        let total = prepared.reduce(0) { $0 + $1.prompt.count + 2 }
        let limit = total <= singleRequestLimit ? total + 1_000 : max(40_000, total / 3 + 2_000)
        return MeetingSource.windows(prepared, limit: limit)
    }

    /// One hosted read per chunk, validated exactly like on-device output.
    /// Throws on any provider or decode failure so the caller can fall back.
    static func extract(prepared: [MeetingSourceTurn], sources: [Int: MeetingSourceTurn], meeting: Meeting,
                        provider: WritingModelProvider, cacheURL: URL?,
                        progress: MeetingNotesService.Progress) async throws -> Result {
        let listening = meeting.captureKind == .listening
        let debug = ProcessInfo.processInfo.environment["MAN_NOTES_DEBUG"] == "1"
        let windows = chunks(prepared)
        var result = Result(chunks: windows.count, transcriptChars: prepared.reduce(0) { $0 + $1.text.count })
        var overviews: [String] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            await progress(windows.count == 1 ? "Reading the whole transcript…" : "Reading the transcript · \(index + 1) of \(windows.count)…")
            let cacheKey = "hosted-v1:" + provider.id + ":" + meeting.kind + ":" + window
            if let cached = await MeetingNotesCache.shared.value(for: cacheKey, at: cacheURL) {
                result.facts += cached.facts; result.actions += cached.actions; result.unclear += cached.unclear
                if let overview = cached.overview { overviews.append(overview) }
                continue
            }
            let response = try await provider.generate(WritingRequest(instructions: HostedExtraction.instructions(listening: listening),
                                                                      input: window, jsonSchema: HostedExtraction.schema,
                                                                      deadline: 120, purpose: .meetingNotes))
            result.inputTokens += response.inputTokens; result.outputTokens += response.outputTokens
            let extraction = try HostedExtraction.decode(response.text)
            var unclear = 0
            let facts = GroundedMeetingNotes.acceptFacts(extraction.facts.map {
                MeetingFact(sourceID: $0.sourceID, text: $0.text, quote: $0.quote, importance: min(3, max(1, $0.importance)),
                            kind: MeetingClaimKind(rawValue: $0.kind))
            }, sources: sources, unclear: &unclear, debug: debug)
            let actions = listening ? [] : GroundedMeetingNotes.acceptCommitments(extraction.commitments.map {
                MeetingCommitment(sourceID: $0.sourceID, owner: $0.owner, task: $0.task, quote: $0.quote, due: $0.due,
                                  confidence: min(1, max(0, $0.confidence)), tentative: $0.tentative)
            }, sources: sources, debug: debug)
            result.facts += facts; result.actions += actions; result.unclear += unclear
            overviews.append(extraction.overview)
            await MeetingNotesCache.shared.save(.init(facts: facts, actions: actions, unclear: unclear, overview: extraction.overview),
                                                source: cacheKey, at: cacheURL)
        }
        if !listening {
            // A promise the model skipped is still a follow-up: the speaker's
            // own sentence, verbatim, exactly as the on-device path does.
            let covered = Set(result.actions.map(\.sourceID))
            for turn in prepared where !covered.contains(turn.id) && MeetingEvidence.mentionsFollowUp(turn.text) {
                if let literal = MeetingEvidence.literalFollowUp(in: turn) { result.actions.append(literal) }
            }
        }
        // One chunk: its overview. Several: the first sentence of each, so the
        // overview still covers the whole meeting within the validator's limit.
        let candidates = overviews.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        result.overview = candidates.count <= 1 ? (candidates.first ?? "")
            : candidates.compactMap { MeetingNoteSections.sentences($0).first }.joined(separator: " ")
        return result
    }
}
