import Foundation
import NaturalLanguage

enum MeetingNoteSections {
    static func isSubstantive(_ text: String) -> Bool {
        let smallTalk = ["how's your day", "how is your day", "back to school", "your kids", "old are", "same school", "different schools", "offsite next week", "virtually meet", "coming out of today's call"]
        return !smallTalk.contains { text.localizedCaseInsensitiveContains($0) }
            && !MeetingEvidence.isAgendaPrompt(text)
    }

    static func salience(_ text: String) -> Int {
        let cues = ["process", "friction", "staff", "foundation", "signal", "customer", "journey", "partner", "commit", "scale", "decision", "because", "instead", "success", "tension", "speed up"]
        return cues.filter { text.localizedCaseInsensitiveContains($0) }.count * 4
            + Set(MeetingSource.words(text).filter { $0.count > 5 }).count
    }
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        return result
    }

    /// Extractive by construction: quotes are exact source substrings, never
    /// model paraphrases. Rank beliefs/decisions, keeping coverage across time.
    static func quotes(meeting: Meeting) -> String {
        let owner = meeting.ownerName.isEmpty ? NSFullUserName() : meeting.ownerName
        let turns = MeetingSource.publicTurns(MeetingSource.parse(meeting.transcript))
        var candidates: [(source: MeetingSourceTurn, text: String, score: Int)] = []
        for turn in turns where !["You", owner, meeting.resolvedOwner].contains(turn.speaker) && !MeetingSource.genericSpeaker(turn.speaker) {
            for sentence in sentences(turn.text) {
                let words = MeetingSource.words(sentence)
                guard (6...45).contains(words.count), !sentence.contains("?"), MeetingEvidence.legible(sentence),
                      isSubstantive(sentence), sentence.last == ".",
                      !["and", "um", "uh", "the", "to", "that"].contains(words.last ?? "") else { continue }
                let cues = ["think", "believe", "need", "important", "success", "focus", "relationship", "foundation", "friction", "decided", "tension", "speed up"]
                let score = cues.filter { sentence.localizedCaseInsensitiveContains($0) }.count + salience(sentence)
                guard score > 0 else { continue }
                candidates.append((turn, sentence, score))
            }
        }
        var selected: [(source: MeetingSourceTurn, text: String, score: Int)] = []
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.source.id < $1.source.id : $0.score > $1.score }) {
            guard !selected.contains(where: { $0.text == candidate.text || abs($0.source.seconds - candidate.source.seconds) < 45 }) else { continue }
            selected.append(candidate)
            if selected.count == 8 { break }
        }
        let lines = selected.sorted { $0.source.id < $1.source.id }.map { "- “\($0.text)” — \($0.source.speaker) [\($0.source.timestamp)]" }
        return "## Quotes\n\n" + (lines.isEmpty ? "No clear, attributable quotes found." : lines.joined(separator: "\n"))
    }

    static func interview(meeting: Meeting) -> String {
        guard MeetingInterviewContext.isInterview(meeting.title) else { return "" }
        let owner = meeting.ownerName.isEmpty ? NSFullUserName() : meeting.ownerName
        let turns = MeetingSource.publicTurns(MeetingSource.parse(meeting.transcript))
        func isOwner(_ turn: MeetingSourceTurn) -> Bool { ["You", owner, meeting.resolvedOwner].contains(turn.speaker) }
        var pairs: [String] = []
        for (index, turn) in turns.enumerated() where !isOwner(turn) {
            guard let question = sentences(turn.text).last(where: { $0.contains("?") && MeetingSource.words($0).count >= 6 && isSubstantive($0) }),
                  let reply = turns.dropFirst(index + 1).first(where: isOwner), reply.seconds - turn.seconds < 45,
                  let answer = sentences(reply.text).first(where: { MeetingSource.words($0).count >= 8 }) else { continue }
            pairs.append("- **Asked [\(turn.timestamp)]:** \(question)\n  **\(owner), answer excerpt [\(reply.timestamp)]:** \(answer)")
            if pairs.count == 5 { break }
        }
        guard !pairs.isEmpty else { return MeetingInterviewContext.unmatchedQuestions(for: meeting) }
        return "\n\n## Interview questions and answers\n\n" + pairs.joined(separator: "\n") + MeetingInterviewContext.unmatchedQuestions(for: meeting)
    }
}
