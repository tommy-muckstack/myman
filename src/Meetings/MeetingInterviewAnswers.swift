import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingInterviewAnswer: Codable, Sendable {
    var question: String
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
        for index in blocks.indices where !owners.contains(blocks[index].speaker) {
            let block = blocks[index]
            guard index + 1 < blocks.count, owners.contains(blocks[index + 1].speaker),
                  MeetingSource.words(blocks[index + 1].text).count >= 35,
                  let questionStart = block.turns.firstIndex(where: { directedQuestion($0.text) }) else { continue }
            let questionTurns = Array(block.turns[questionStart...])
            let question = questionTurns.map(\.text).joined(separator: " ")
            var answerTurns = blocks[index + 1].turns
            var next = index + 2
            while next + 1 < blocks.count, !owners.contains(blocks[next].speaker),
                  owners.contains(blocks[next + 1].speaker),
                  MeetingSource.words(blocks[next].text).count <= 45,
                  !directedQuestion(blocks[next].text) {
                // Brief clarification or recognition ("let's go with that
                // example", "I've used that product") does not ask something new.
                answerTurns += blocks[next + 1].turns
                next += 2
            }
            let answer = MeetingInterviewAnswer(question: question, questionTime: questionTurns[0].timestamp,
                speaker: meeting.resolvedOwner, turns: answerTurns)
            if let parent = answers.last, isFollowUp(question, to: parent) {
                answers[answers.count - 1].followUps.append(answer)
            } else { answers.append(answer) }
        }
        return answers
    }

    static func directedQuestion(_ text: String) -> Bool {
        let lower = MeetingSource.normalized(text)
        let excluded = ["anything i could answer", "anything i can answer", "how s your", "how are you", "who have you spoken", "where are you from"]
        guard !excluded.contains(where: lower.contains) else { return false }
        let patterns = [#"\bwhat (do|did|would|could) you\b"#, #"\bhow (do|did|would|could) you\b"#,
                        #"\b(can|could|would) you (tell|walk|describe|explain|give|share)\b"#,
                        #"\btell me about\b"#, #"\bfrom your perspective\b"#,
                        #"\bis there anything.*you\b"#]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func isFollowUp(_ question: String, to parent: MeetingInterviewAnswer) -> Bool {
        let lower = MeetingSource.normalized(question)
        if lower.range(of: #"tell me about (a |an |another |some |a specific )"#, options: .regularExpression) != nil
            || lower.contains("from your perspective") { return false }
        let references = ["that project", "this project", "what was missed", "outside of your control", "reflect on", "follow up", "to that point"]
        if references.contains(where: lower.contains)
            || lower.range(of: #"what.*(?:was missed|did you own)"#, options: .regularExpression) != nil { return true }
        let stop: Set<String> = ["what", "which", "where", "there", "their", "would", "could", "about", "think", "believe", "like", "that", "this", "your", "have", "from", "with", "more", "some", "kind", "terms", "very", "into", "when"]
        let words = Set(MeetingSource.words(question).filter { $0.count > 3 && !stop.contains($0) })
        let prior = Set(MeetingSource.words(parent.question + " " + parent.turns.map(\.text).joined(separator: " ")).filter { $0.count > 3 && !stop.contains($0) })
        // A continuation shares substantive vocabulary and explicitly refers
        // back to an answer, rather than merely sharing interview boilerplate.
        let continuation = ["structurally", "cultural piece", "you mentioned", "you said", "on that", "in that case", "more specifically"]
        return continuation.contains(where: lower.contains) && words.intersection(prior).count >= 2
    }

    static func summarize(_ exchanges: [MeetingInterviewAnswer], useLanguageModel: Bool,
                          progress: @escaping MeetingNotesService.Progress) async -> [MeetingInterviewAnswer] {
        var result = exchanges
        for index in result.indices {
            guard !Task.isCancelled else { break }
            await progress("Reading complete interview answers · \(index + 1) of \(result.count)…")
            result[index].bullets = await summarizeAnswer(result[index], useLanguageModel: useLanguageModel)
            for follow in result[index].followUps.indices {
                result[index].followUps[follow].bullets = await summarizeAnswer(result[index].followUps[follow], useLanguageModel: useLanguageModel)
            }
        }
        return result
    }

    private static func summarizeAnswer(_ answer: MeetingInterviewAnswer, useLanguageModel: Bool) async -> [String] {
        let evidence = answer.turns.map(\.text).joined(separator: " ")
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useLanguageModel, case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
                Summarize the complete answer in two to four concise bullets of 12 to 35 words each. Cover the explanation, concrete examples, tradeoffs, and outcome across the whole answer. Use the answer's actual nouns and terminology. Write the point directly, without "the respondent explains" or similar introductions. Do not summarize the question or invent intentions, promises, facts, causality, or dates. Preserve negation and uncertainty. Speaker attribution is supplied by the app. Output only bullets, without a heading.
                """)
            if let response = try? await AsyncDeadline.run(seconds: 20, operation: {
                try await session.respond(to: "Question: \(answer.question)\nRespondent's answer:\n\(evidence)", options: .init(sampling: .greedy)).content
            }) {
                if ProcessInfo.processInfo.environment["MAN_NOTES_DEBUG"] == "1" {
                    print("INTERVIEW_MODEL [\(answer.questionTime)] \(response)"); fflush(stdout)
                }
                let bullets = response.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t")) }
                    .filter { (6...65).contains(MeetingSource.words($0).count) && MeetingNoteSections.completeSentence($0)
                        && MeetingEvidence.groundedWording($0, in: evidence) && MeetingEvidence.legible($0) }
                if (2...4).contains(bullets.count) { return bullets }
            }
        }
        #endif
        // Keep the full span navigable instead of presenting its first clause
        // as an answer. A failed summary is explicit and can be regenerated.
        return []
    }

    static func render(_ answers: [MeetingInterviewAnswer]) -> String {
        guard !answers.isEmpty else { return "" }
        func body(_ answer: MeetingInterviewAnswer, level: Int) -> String {
            let header = String(repeating: "#", count: level)
            var text = "\(header) \(level == 4 ? "Follow-up" : "Question") [\(answer.questionTime)]\n\n\(answer.question)\n\n**\(answer.speaker)’s answer \(answer.range)**\n\n"
            text += answer.bullets.isEmpty
                ? "Answer summary unavailable; review the full answer at \(answer.range) or regenerate notes."
                : answer.bullets.map { "- " + $0 }.joined(separator: "\n")
            for follow in answer.followUps { text += "\n\n" + body(follow, level: 4) }
            return text
        }
        return "\n\n## Interview questions and answers\n\n" + answers.map { body($0, level: 3) }.joined(separator: "\n\n")
    }
}
