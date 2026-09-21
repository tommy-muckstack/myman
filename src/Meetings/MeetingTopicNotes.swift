import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingTopic: Codable, Sendable {
    var title: String
    var startID: Int
    var endID: Int
    var facts: [MeetingFact] = []
}

/// Plan subjects before extracting facts. Recorder chunks are evidence anchors,
/// not topic boundaries. Cached topic reads make live drafts useful at call end.
enum MeetingTopicNotes {
    static func generate(_ meeting: Meeting, corrections: [String: String], useLanguageModel: Bool,
                         progress: @escaping MeetingNotesService.Progress) async -> MeetingAnalysis {
        let originalTranscript = meeting.transcript
        var meeting = meeting
        let nameInput = meeting
        let scopedNames = await Task.detached(priority: .utility) { MeetingPeopleContext.names(for: nameInput) }.value
        meeting.transcript = MeetingPeopleContext.correct(meeting.transcript, names: scopedNames).text
        let raw = MeetingSource.notesTurns(MeetingSource.parse(meeting.transcript))
        let prepared = MeetingSource.paragraphs(raw).map { turn in
            MeetingSourceTurn(id: turn.id, speaker: turn.speaker == "You" ? meeting.resolvedOwner : turn.speaker,
                timestamp: turn.timestamp, text: MeetingVocabulary.correct(turn.text, terms: [], aliases: corrections).text)
        }
        let sources = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0) })
        let cache = MeetingNotesCache.url(for: meeting)
        let segmentationInput = raw
        let windows = await Task.detached(priority: .utility) { MeetingTopicSegmentation.segments(segmentationInput) }.value
        let outline = windows.enumerated().map { "Window \($0.offset): " + outlineSource($0.element) }.joined(separator: "\n")
        let planKey = "topic-plan-v6:" + outline
        var topics = await MeetingNotesCache.shared.value(for: planKey, at: cache)?.topics ?? []
        var modelAvailable = false
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), useLanguageModel, case .available = SystemLanguageModel.default.availability {
            modelAvailable = true
            if topics.isEmpty {
                await progress("Finding the main subjects…")
                for (index, window) in windows.enumerated() {
                    guard !Task.isCancelled else { return .init(markdown: "") }
                    let full = window.map(\.prompt).joined(separator: "\n")
                    let middle = full.index(full.startIndex, offsetBy: max(0, full.count / 2 - 900))
                    let text = full.count <= 6000 ? full : String(full.prefix(1800)) + "\n…\n" + String(full[middle...].prefix(1800)) + "\n…\n" + String(full.suffix(1800))
                    let prior = ""
                    let key = "subject-window-v3:" + prior + text
                    if let cached = await MeetingNotesCache.shared.value(for: key, at: cache), let stored = cached.topics {
                        if let topic = stored.first {
                            if topics.last?.title == topic.title { topics[topics.count - 1].endID = topic.endID }
                            else { topics.append(topic) }
                        }
                        continue
                    }
                    await progress("Finding subjects · \(index + 1) of \(windows.count)…")
                    let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
                        Identify the work subject in this short meeting passage. Ignore travel, family, health, sports and history: these are small talk, not work topics. isWork is true only for a sustained discussion of a project, deliverable, product, or business plan. Title is a short concrete subject using this passage’s distinctive nouns/acronyms only. Avoid vague labels such as Strategy, Communication, Planning, Process, User Experience. Spoken letters like M C P are one acronym. A brief aside does not start a new work subject.
                        """)
                    do {
                        let subject = try await AsyncDeadline.run(seconds: 15) {
                            try await session.respond(to: text, generating: WindowSubject.self, options: .init(sampling: .greedy)).content
                        }
                        var stored: [MeetingTopic] = []
                        if subject.isWork && !subject.title.isEmpty {
                            let topic = MeetingTopic(title: subject.title, startID: window.first!.id, endID: window.last!.id)
                            if topics.last?.title == topic.title { topics[topics.count - 1].endID = topic.endID }
                            else { topics.append(topic) }
                            stored = [topic]
                        }
                        await MeetingNotesCache.shared.save(.init(facts: [], actions: [], unclear: 0, topics: stored), source: key, at: cache)
                    } catch { }
                }
                if !topics.isEmpty {
                    await MeetingNotesCache.shared.save(.init(facts: [], actions: [], unclear: 0, topics: topics), source: planKey, at: cache)
                }
            }
        }
        #endif
        var actions: [MeetingCommitment] = []
        var facts: [MeetingFact] = []
        for index in topics.indices {
            guard !Task.isCancelled else { return .init(markdown: "") }
            let topic = topics[index]
            let turns = prepared.filter { $0.id >= topic.startID && $0.id <= topic.endID }
            for window in MeetingSource.windows(turns, limit: 6200) {
                let key = "topic-read-v7:" + topic.title + ":" + window
                if let cached = await MeetingNotesCache.shared.value(for: key, at: cache) {
                    topics[index].facts += cached.facts; actions += cached.actions
                    continue
                }
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *), modelAvailable {
                    await progress("Summarizing \(topic.title)…")
                    let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
                        Write 2–4 concise meeting-note bullets about the supplied subject. Each bullet must be a complete sentence of 10–35 words, using concrete details from the transcript. Cover what was proposed, why it matters, and constraints. Ignore small talk and damaged ASR clauses. Preserve uncertainty and negation. Do not invent facts, dates, or decisions. Do not name or attribute any speaker: write subject-focused bullets directly. Do not assign actions: another pass handles those. Do not quote or copy long transcript passages. Output only bullets, with no heading or preamble.
                        """)
                    do {
                        let response = try await AsyncDeadline.run(seconds: 25) {
                            try await session.respond(to: "Subject: \(topic.title)\n\n" + window, options: .init(sampling: .greedy)).content
                        }
                        let bullets = response.components(separatedBy: .newlines).map {
                            $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t"))
                        }.filter { (6...45).contains(MeetingSource.words($0).count) && $0.count <= 280 }
                        let checked = bullets.compactMap { text -> MeetingFact? in
                            guard MeetingNoteSections.completeSentence(text) else { return nil }
                            let words = Set(MeetingSource.words(text).filter { $0.count >= 4 })
                            guard let turn = turns.max(by: {
                                words.intersection(MeetingSource.words($0.text)).count < words.intersection(MeetingSource.words($1.text)).count
                            }) else { return nil }
                            let evidence = turns.map(\.prompt).joined(separator: " ")
                            guard MeetingEvidence.groundedWording(text, in: evidence), MeetingEvidence.legible(text),
                                  !MeetingEvidence.consequential(text) || MeetingEvidence.verbsGrounded(text, in: evidence) else {
                                if ProcessInfo.processInfo.environment["MAN_NOTES_DEBUG"] == "1" { print("TOPIC_REJECTED: \(text)") }
                                return nil
                            }
                            return MeetingFact(sourceID: turn.id, text: text, quote: turn.text, importance: 3, kind: .discussion)
                        }
                        topics[index].facts += checked
                        await MeetingNotesCache.shared.save(.init(facts: checked, actions: [], unclear: 0), source: key, at: cache)
                    } catch {
                        // A failed topic does not disable extraction for later subjects.
                        if ProcessInfo.processInfo.environment["MAN_NOTES_DEBUG"] == "1" { print("TOPIC_READ_FAILED: \(error)") }
                    }
                }
                #endif
            }
            topics[index].facts = Array(GroundedMeetingNotes.selectFacts(topics[index].facts).prefix(4))
            facts += topics[index].facts
        }
        // Commitments are always scanned independently, including the closing
        // minutes and passages the topic planner excluded.
        actions += prepared.compactMap { MeetingEvidence.literalFollowUp(in: $0) }
        actions = GroundedMeetingNotes.selectActions(actions)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), modelAvailable {
            for index in actions.indices {
                let action = actions[index]
                guard let turn = sources[action.sourceID] else { continue }
                let evidence = prepared.filter { $0.speaker == turn.speaker && $0.seconds >= turn.seconds - 60 && $0.seconds <= turn.seconds }.map(\.prompt).joined(separator: " ")
                let key = "action-wording-v2:" + action.quote + evidence
                if let cached = await MeetingNotesCache.shared.value(for: key, at: cache), let saved = cached.actions.first {
                    actions[index] = saved; continue
                }
                await progress("Clarifying \(action.owner)’s follow-up…")
                let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: "Write one concise task title starting with an imperative verb. Resolve vague objects in the quoted promise using ONLY the surrounding transcript. Preserve the speaker’s actual promise. Include the deliverable and format when stated. No owner, date, explanation, quotation marks or bullets. Do not invent a task.")
                if let text = try? await AsyncDeadline.run(seconds: 15, operation: {
                    try await session.respond(to: "Promise: \(action.quote)\nContext: \(evidence)", options: .init(sampling: .greedy)).content
                }) {
                    var candidate = action; candidate.task = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !Set(meeting.participants.flatMap { MeetingSource.words($0.name) }).contains(where: { MeetingSource.words(candidate.task).contains($0) && !MeetingSource.words(action.quote).contains($0) }), let checked = MeetingEvidence.commitment(candidate, sources: sources) {
                        actions[index] = checked
                        await MeetingNotesCache.shared.save(.init(facts: [], actions: [checked], unclear: 0), source: key, at: cache)
                    }
                }
            }
        }
        #endif
        let parsed = MeetingSource.parse(meeting.transcript)
        let omitted = MeetingSource.omitPrivateNotes && MeetingSource.publicTurns(parsed).count < parsed.filter { !MeetingSource.isBackchannel($0.text) }.count
        var result = "## Overview\n\n"
        let substantive = topics.filter { !$0.facts.isEmpty }
        if substantive.isEmpty {
            result += "Topic summary unavailable. The full transcript and attributable quotes are saved below; regenerate notes to retry."
        } else {
            result += "Discussed " + substantive.map(\.title).joined(separator: "; ") + "."
            result += "\n\n## Main topics\n\n" + substantive.map { topic in
                let start = raw.first { $0.id >= topic.startID }?.timestamp ?? ""
                let end = raw.last { $0.id <= topic.endID }?.timestamp ?? start
                return "### \(topic.title) [\(start)–\(end)]\n\n" + topic.facts.map { "- " + $0.text }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        let answers = await MeetingInterviewAnswers.summarize(MeetingInterviewAnswers.exchanges(meeting),
            useLanguageModel: modelAvailable, progress: progress)
        let remainder = GroundedMeetingNotes.render(facts: facts.filter { $0.resolvedKind != .discussion }, actions: actions,
            sources: sources, meeting: meeting, privateOmitted: omitted, interviewAnswers: answers)
        if let section = remainder.range(of: "\n\n## Decisions and alignment") ?? remainder.range(of: "\n\n## Next steps") {
            result += String(remainder[section.lowerBound...])
        }
        result += unresolvedReferences(in: raw, participants: meeting.participants)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), modelAvailable {
            let candidates = MeetingNoteSections.quotes(meeting: meeting, limit: 32, separation: 15)
                .components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
            if candidates.count >= 5 {
                await progress("Selecting clear, attributable quotes…")
                let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: "Select five to eight clean quotes from the numbered candidates. Prefer concise statements of belief, decisions, plans or useful principles, from BOTH speakers. Reject unfinished clauses, bad grammar, ASR damage, historical dates, greetings and conversational filler. Return only the candidate numbers. Never rewrite their words.")
                let prompt = candidates.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
                if let choice = try? await AsyncDeadline.run(seconds: 15, operation: {
                    try await session.respond(to: prompt, generating: QuoteSelection.self, options: .init(sampling: .greedy)).content
                }) {
                    let chosen = Set(choice.indices).filter { candidates.indices.contains($0) }.sorted()
                    if chosen.count >= 5, let start = result.range(of: "## Quotes\n\n") {
                        let end = result.range(of: "\n\n## ", range: start.upperBound..<result.endIndex)?.lowerBound ?? result.endIndex
                        result.replaceSubrange(start.upperBound..<end, with: chosen.prefix(8).map { candidates[$0] }.joined(separator: "\n"))
                    }
                }
            }
        }
        #endif
        var analysis = MeetingAnalysis(markdown: result, facts: facts, actions: actions, omittedPrivatePassages: omitted)
        analysis.correctedTranscript = meeting.transcript == originalTranscript ? nil : meeting.transcript
        analysis.omissionEnabled = MeetingSource.omitPrivateNotes
        return analysis
    }

    /// A compact chronological index, with all eligible boundary IDs. It fits
    /// the local model even when the transcript itself exceeds its context.
    static func outlineWindows(_ turns: [MeetingSourceTurn]) -> [[MeetingSourceTurn]] {
        let groups = Dictionary(grouping: turns) { Int($0.seconds / 90) }
        return groups.keys.sorted().map { groups[$0]! }
    }

    static func outlineSource(_ turns: [MeetingSourceTurn]) -> String {
        let text = turns.map(\.text).joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.lexicalClass]); tagger.string = text
        var nouns: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            let word = String(text[range])
            if tag == .noun && word.count >= 3 { nouns[word.lowercased(), default: 0] += 1 }
            return true
        }
        let stop: Set<String> = ["thing", "things", "time", "kind", "lot", "bit", "way", "stuff", "something", "people", "point"]
        let keywords = nouns.filter { !stop.contains($0.key) }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map(\.key).joined(separator: ", ")
        let sentences = MeetingNoteSections.sentences(text).filter { MeetingSource.words($0).count >= 6 }
        let sample = sentences.sorted { MeetingNoteSections.salience($0) > MeetingNoteSections.salience($1) }.prefix(2).map { String($0.prefix(150)) }.joined(separator: " ")
        return "[\(turns.first?.timestamp ?? "")–\(turns.last?.timestamp ?? "")] Keywords: \(keywords). \(sample)"
    }

    static func unresolvedReferences(in turns: [MeetingSourceTurn], participants: [MeetingParticipant]) -> String {
        let names = Set(participants.flatMap { MeetingSource.words($0.name) })
        var lines: [String] = []
        for (index, turn) in turns.enumerated() {
            let words = MeetingSource.words(turn.text)
            guard let first = words.first, ["he", "she"].contains(first), words.count >= 8 else { continue }
            let preceding = turns[..<index].filter { turn.seconds - $0.seconds <= 30 }.map(\.text).joined(separator: " ")
            let named = !Set(MeetingSource.words(preceding)).isDisjoint(with: names)
            let context = turn.text + " " + turns.dropFirst(index + 1).prefix(3).map(\.text).joined(separator: " ")
            guard !named, ["customer", "team", "sick", "project", "engineer", "manager", "colleague"].contains(where: { context.localizedCaseInsensitiveContains($0) }) else { continue }
            lines.append("- [unnamed team member] — \(turn.speaker) said “\(turn.text)” [\(turn.timestamp)]. Confirm who this refers to.")
            if lines.count == 4 { break }
        }
        return lines.isEmpty ? "" : "\n\n## Needs the owner\n\n" + lines.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *) @Generable fileprivate struct QuoteSelection {
        @Guide(description: "Indices of five to eight clear, complete, useful quotes, from both speakers.", .count(5...8)) var indices: [Int]
    }
    @available(macOS 26.0, *) @Generable fileprivate struct WindowSubject {
        @Guide(description: "The dominant subject in the passage, using its concrete nouns. Ignore previous or incidental subjects.") var title: String
        @Guide(description: "False if most of the passage is personal conversation, travel, history, sports, health, pets, or greetings. True only if most concerns substantive work.") var isWork: Bool
    }
    @available(macOS 26.0, *) @Generable fileprivate struct PlannedTopic {
        var title: String
        var startWindow: Int
        var endWindow: Int
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Plan {
        @Guide(description: "Main work subjects, excluding small talk.", .count(0...6)) var topics: [PlannedTopic]
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Fact {
        var sourceID: Int
        var quote: String
        var text: String
        var kind: String
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Action {
        var sourceID: Int
        var quote: String
        var owner: String
        var task: String
        var due: String
        var proposed: Bool
    }
    @available(macOS 26.0, *) @Generable fileprivate struct Summary {
        @Guide(.count(2...4)) var facts: [Fact]
        @Guide(.count(0...5)) var actions: [Action]
    }
    #endif
}
