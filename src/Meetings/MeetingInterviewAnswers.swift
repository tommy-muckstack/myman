import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingInterviewAnswer: Codable, Sendable {
    var question: String
    var questioner: String? = nil
    var ownerAnswer: Bool? = nil
    var extractive: Bool? = nil
    var questionTime: String
    var speaker: String
    var turns: [MeetingSourceTurn]
    var bullets: [String] = []
    var followUps: [MeetingInterviewAnswer] = []
    var range: String { "[\(turns.first?.timestamp ?? questionTime)–\(turns.last?.timestamp ?? questionTime)]" }
}

/// Reconstruct the exchange before asking a model to summarize it. Recorder
/// chunk boundaries and brief acknowledgments are not answer boundaries.
enum MeetingInterviewAnswers {
    private struct Block {
        var speaker: String
        var turns: [MeetingSourceTurn]
        var text: String { turns.map(\.text).joined(separator: " ") }
    }

    static func exchanges(_ meeting: Meeting) -> [MeetingInterviewAnswer] {
        guard MeetingInterviewContext.isInterview(meeting.title) else { return [] }
        let turns = MeetingSource.notesTurns(MeetingSource.parse(meeting.transcript))
        let owners = Set(["You", meeting.ownerName, meeting.resolvedOwner])
        var blocks: [Block] = []
        for turn in turns {
            let words = MeetingSource.words(turn.text)
            // A short interjection can complete the question while the answer
            // has already started ("where it's relevant"). Keep the answer.
            if words.count <= 6, let last = blocks.last, last.speaker != turn.speaker,
               !directedQuestion(turn.text),
               !["why", "how", "what do you mean"].contains(MeetingSource.normalized(turn.text)) { continue }
            if blocks.last?.speaker == turn.speaker {
                blocks[blocks.count - 1].turns.append(turn)
            } else { blocks.append(Block(speaker: turn.speaker, turns: [turn])) }
        }
        var answers: [MeetingInterviewAnswer] = []
        for index in blocks.indices {
            let block = blocks[index]
            guard index + 1 < blocks.count,
                  block.speaker != blocks[index + 1].speaker,
                  MeetingSource.words(blocks[index + 1].text).count >= 35 else { continue }
            // Interrogative stems can straddle ASR chunks and need no "?".
            // Invitation wording plus a long response is also a directed turn.
            let questionStart = block.turns.firstIndex { directedQuestion($0.text) }
                ?? block.turns.indices.first { offset in
                    directedQuestion(block.turns.dropFirst(offset).prefix(3).map(\.text).joined(separator: " "))
                }
            guard let questionStart else { continue }
            let questionTurns = owners.contains(block.speaker) ? block.turns : Array(block.turns[questionStart...])
            let question = questionTurns.map(\.text).joined(separator: " ")
            let respondent = blocks[index + 1].speaker
            var answerTurns = blocks[index + 1].turns
            var next = index + 2
            while next + 1 < blocks.count, blocks[next].speaker == block.speaker,
                  blocks[next + 1].speaker == respondent,
                  MeetingSource.words(blocks[next].text).count <= 45,
                  !directedQuestion(blocks[next].text) {
                answerTurns += blocks[next + 1].turns
                next += 2
            }
            let answer = MeetingInterviewAnswer(question: question, questioner: block.speaker,
                ownerAnswer: owners.contains(respondent), questionTime: questionTurns[0].timestamp,
                speaker: owners.contains(respondent) ? meeting.resolvedOwner : respondent, turns: answerTurns)
            if let parent = answers.last, parent.speaker == answer.speaker,
               isFollowUp(question, to: parent) {
                answers[answers.count - 1].followUps.append(answer)
            } else { answers.append(answer) }
        }
        // A respondent may finish their answer and ask the next question
        // without a speaker change. Exclude that detected question from the
        // preceding answer rather than summarizing it as something they said.
        let questions = answers.flatMap { [$0] + $0.followUps }
        for index in answers.indices {
            let cut = questions.compactMap { question -> Int? in
                answers[index].turns.firstIndex { $0.timestamp == question.questionTime && $0.speaker == question.questioner }
            }.min()
            if let cut, cut > 0 { answers[index].turns = Array(answers[index].turns[..<cut]) }
        }
        return answers
    }

    static func directedQuestion(_ text: String) -> Bool {
        let lower = MeetingSource.normalized(text).replacingOccurrences(of: "what do you think", with: "")
        let excluded = ["anything i could answer", "anything i can answer", "how can i help", "any questions for", "how s your", "how are you", "who have you spoken", "where are you from"]
        guard !excluded.contains(where: lower.contains), lower != "what do you think" else { return false }
        let patterns = [#"\bis there (an? example|one experience)\b"#,
                        #"\bwhat (s|is) (your|the last|the next)\b"#,
                        #"\bwhat (makes you|would you|needs to be true|are the barriers|are the bottlenecks)\b"#,
                        #"\bwhy (why )?(this role|did you|have you)\b"#,
                        #"\b(love to hear|hear your|share with me|walk me through|your take on|your thoughts on)\b"#,
                        #"\b(have you been|are they|is that happening|who (owns|leads|reports))\b"#,
                        #"\bhow\b.*\b(collaborate|partner|split|scope)\b"#,
                        #"\bwhat (do|did|would|could) you\b"#, #"\bhow (do|did|would|could) you\b"#,
                        #"\b(can|could|would) you (tell|walk|describe|explain|give|share)\b"#,
                        #"\btell me about\b"#, #"\bfrom your perspective\b"#,
                        #"\bis there anything.*you\b"#]
        if lower == "what do you think" { return false }
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func isFollowUp(_ question: String, to parent: MeetingInterviewAnswer) -> Bool {
        let lower = MeetingSource.normalized(question)
        if lower.range(of: #"tell me about (a |an |another |some |a specific )"#, options: .regularExpression) != nil
            || lower.contains("from your perspective") || lower.contains("last question") { return false }
        if lower.contains("why did you wanna"), parent.question.localizedCaseInsensitiveContains("built") { return true }
        let references = ["that project", "this project", "what was missed", "outside of your control", "reflect on", "follow up", "to that point", "things you re looking for", "one experience in your background", "next thing you re gonna work on"]
        if references.contains(where: lower.contains)
            || lower.range(of: #"what.*(?:was missed|did you own)"#, options: .regularExpression) != nil { return true }
        let stop: Set<String> = ["what", "which", "where", "there", "their", "would", "could", "about", "think", "believe", "like", "that", "this", "your", "have", "from", "with", "more", "some", "kind", "terms", "very", "into", "when"]
        let words = Set(MeetingSource.words(question).filter { $0.count > 3 && !stop.contains($0) })
        let prior = Set(MeetingSource.words(parent.question + " " + parent.turns.map(\.text).joined(separator: " ")).filter { $0.count > 3 && !stop.contains($0) })
        // A continuation shares substantive vocabulary and explicitly refers
        // back to an answer, rather than merely sharing interview boilerplate.
        let continuation = ["structurally", "cultural piece", "you mentioned", "you said", "in that case", "more specifically"]
        return continuation.contains(where: lower.contains) && words.intersection(prior).count >= 2
    }

    static func summarize(_ exchanges: [MeetingInterviewAnswer], useLanguageModel: Bool,
                          progress: @escaping MeetingNotesService.Progress) async -> [MeetingInterviewAnswer] {
        var result = exchanges
        for index in result.indices {
            guard !Task.isCancelled else { break }
            await progress("Reading complete interview answers · \(index + 1) of \(result.count)…")
            result[index].bullets = await summarizeAnswer(result[index], useLanguageModel: useLanguageModel)
            result[index].extractive = result[index].bullets.allSatisfy { $0.hasPrefix("“") }
            for follow in result[index].followUps.indices {
                result[index].followUps[follow].bullets = await summarizeAnswer(result[index].followUps[follow], useLanguageModel: useLanguageModel)
                result[index].followUps[follow].extractive = result[index].followUps[follow].bullets.allSatisfy { $0.hasPrefix("“") }
            }
        }
        return result
    }

    private static func summarizeAnswer(_ answer: MeetingInterviewAnswer, useLanguageModel: Bool) async -> [String] {
        let candidates = excerptCandidates(answer.turns)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useLanguageModel, candidates.count >= 2,
           case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
                Select two to four passage indices that best answer the question. Cover distinct points across the answer: explanation, concrete example, constraints and outcome. Prefer complete, informative statements. Skip greetings, filler, garbled recognition and unfinished clauses. Only select supplied indices. Do not generate or rewrite text.
                """)
            let prompt = "Question: \(answer.question)\nPassages:\n" + candidates.enumerated().map {
                "[\($0.offset)] " + $0.element.text
            }.joined(separator: "\n")
            if let picked = try? await AsyncDeadline.run(seconds: 10, operation: {
                try await session.respond(to: prompt, generating: PassageSelection.self, options: .init(sampling: .greedy)).content
            }) {
                let indices = Set(picked.indices).filter { candidates.indices.contains($0) }.sorted()
                if (2...4).contains(indices.count) {
                    return indices.map { "“\(candidates[$0].text)” [\(candidates[$0].time)]" }
                }
            }
        }
        #endif
        return excerpts(answer.turns)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *) @Generable fileprivate struct PassageSelection {
        @Guide(description: "Two to four different supplied passage indices covering the answer.", .count(2...4))
        var indices: [Int]
    }
    #endif

    struct Excerpt {
        var text: String
        var time: String
        var score: Int
    }

    static func excerptCandidates(_ turns: [MeetingSourceTurn]) -> [Excerpt] {
        let paragraphs = MeetingSource.paragraphs(turns)
        var candidates: [Excerpt] = []
        for paragraph in paragraphs {
            for sentence in MeetingNoteSections.sentences(paragraph.text) {
                guard (8...65).contains(MeetingSource.words(sentence).count),
                      MeetingNoteSections.completeSentence(sentence),
                      MeetingNoteSections.quoteHasSubject(sentence), MeetingEvidence.legible(sentence),
                      !MeetingEvidence.isAgendaPrompt(sentence) else { continue }
                let anchor = MeetingNoteSections.quoteAnchor(sentence, paragraph: paragraph, originals: turns)
                candidates.append(Excerpt(text: sentence, time: anchor.timestamp, score: MeetingNoteSections.salience(sentence)))
            }
        }
        // Bound local model context while retaining coverage across the answer.
        if candidates.count > 24 {
            candidates = (0..<24).compactMap { bucket in
                let start = bucket * candidates.count / 24, end = (bucket + 1) * candidates.count / 24
                return candidates[start..<end].max { $0.score < $1.score }
            }
        }
        return candidates
    }

    /// An honest fallback: complete source sentences distributed across the
    /// answer, explicitly labeled as excerpts instead of a generated summary.
    static func excerpts(_ turns: [MeetingSourceTurn], limit: Int = 4) -> [String] {
        let candidates = excerptCandidates(turns)
        guard !candidates.isEmpty else { return [] }
        let count = min(limit, candidates.count)
        return (0..<count).compactMap { bucket in
            let start = bucket * candidates.count / count, end = (bucket + 1) * candidates.count / count
            guard let best = candidates[start..<end].max(by: { $0.score < $1.score }) else { return nil }
            return "“\(best.text)” [\(best.time)]"
        }
    }

    static func render(_ answers: [MeetingInterviewAnswer], owner: String? = nil) -> String {
        guard !answers.isEmpty else { return "" }
        func body(_ answer: MeetingInterviewAnswer, level: Int, followUp: Bool = false) -> String {
            let header = String(repeating: "#", count: level)
            var text = "\(header) \(followUp ? "Follow-up" : "Question") [\(answer.questionTime)]\n\n\(answer.question)\n\n**\(answer.speaker)’s answer \(answer.range)**\n\n"
            if answer.extractive == true { text += "*Source excerpts; extractive digest; no paraphrase.*\n\n" }
            text += answer.bullets.isEmpty
                ? "Answer summary unavailable; review the full answer at \(answer.range) or regenerate notes."
                : answer.bullets.map { "- " + $0 }.joined(separator: "\n")
            for follow in answer.followUps { text += "\n\n" + body(follow, level: 5, followUp: true) }
            return text
        }
        let name = owner?.split(separator: " ").first.map(String.init)
            ?? answers.first(where: { $0.ownerAnswer == true })?.speaker.split(separator: " ").first.map(String.init) ?? "the owner"
        let groups = [("They asked " + name, answers.filter { $0.ownerAnswer != false }),
                      (name + " asked them", answers.filter { $0.ownerAnswer == false })]
        return "\n\n## Interview questions and answers\n\n" + groups.filter { !$0.1.isEmpty }.map {
            "### " + $0.0 + "\n\n" + $0.1.map { body($0, level: 4) }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }
}
