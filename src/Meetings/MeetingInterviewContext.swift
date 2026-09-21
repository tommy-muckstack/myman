import Foundation
import EventKit

struct MeetingInterviewContext: Codable {
    var prepPath: String
    var questions: [String]

    static func url(for meeting: Meeting) -> URL? {
        MeetingTranscriptCheckpoint.url(micPath: meeting.micAudioPath, systemPath: meeting.systemAudioPath)?
            .deletingPathExtension().appendingPathExtension("interview.json")
    }

    static func isInterview(_ title: String) -> Bool {
        let keywords = UserDefaults.standard.stringArray(forKey: "meetingInterviewKeywords") ?? ["CI:"]
        return keywords.contains { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }
    }

    /// Prefer an explicit local calendar link; otherwise use a unique same-day
    /// prep file in a configured company folder for the named interviewee.
    @MainActor static func capture(for meeting: Meeting) {
        guard isInterview(meeting.title), let destination = url(for: meeting) else { return }
        let context = linkedPrep(for: meeting).flatMap { file -> Self? in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
                  let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Self(prepPath: file.path, questions: preparedPrompts(in: content))
        } ?? discover(for: meeting)
        guard let context else { return }
        try? JSONEncoder().encode(context).write(to: destination, options: .atomic)
    }

    @MainActor private static func linkedPrep(for meeting: Meeting) -> URL? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: meeting.startedAt.addingTimeInterval(-1200),
                                                                    end: meeting.startedAt.addingTimeInterval(1200), calendars: nil))
        let matches = events.filter { $0.title == meeting.title }
        guard matches.count == 1, let notes = matches.first?.notes,
              let expression = try? NSRegularExpression(pattern: #"file://[^\s<>\")]+\.md"#),
              let match = expression.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range, in: notes), let file = URL(string: String(notes[range])), file.isFileURL else { return nil }
        return file
    }

    static func discover(for meeting: Meeting, folders: [String: String]? = nil) -> Self? {
        guard isInterview(meeting.title) else { return nil }
        let remote = MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName)?.remote
            ?? meeting.participants.first { !$0.isOwner }?.name
        guard let remote else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: meeting.startedAt)
        let files = MeetingCompanyContext.documents(for: meeting, folders: folders).filter {
            $0.url.path.contains(day) && $0.url.lastPathComponent.localizedCaseInsensitiveContains("prep")
                && $0.text.localizedCaseInsensitiveContains(remote)
        }
        guard files.count == 1, let file = files.first else { return nil }
        return Self(prepPath: file.url.path, questions: preparedPrompts(in: file.text))
    }

    static func preparedPrompts(in content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        // A prep document also contains researched facts and reminders. When
        // it has a questions section, only that section is the interview plan.
        let start = lines.firstIndex { $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains("questions to ask") }
        let selected: [String]
        if let start {
            selected = Array(lines.dropFirst(start + 1).prefix { !$0.hasPrefix("## ") })
        } else { selected = lines }
        return Array(selected.compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let clean = line.replacingOccurrences(of: #"^\s*(?:[-*]|\d+[a-z]?[.)])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let lower = MeetingSource.normalized(clean)
            guard clean.contains("?") || ["how ", "what ", "why ", "where ", "when "].contains(where: lower.hasPrefix) else { return nil }
            return clean
        }.prefix(50))
    }

    static func unmatchedQuestions(for meeting: Meeting) -> String {
        let saved = url(for: meeting).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        guard let context = saved ?? discover(for: meeting) else { return "" }
        return comparison(context, answers: MeetingInterviewAnswers.exchanges(meeting))
    }

    static func comparison(_ context: Self, answers: [MeetingInterviewAnswer]) -> String {
        let ownerQuestions = answers.filter { $0.ownerAnswer == false }.flatMap { [$0] + $0.followUps }
        var asked: [String] = [], notAsked: [String] = [], partial: [String] = []
        for question in context.questions {
            let clauses = question.split(separator: "?").map(String.init).filter { MeetingSource.words($0).count >= 4 }
            let matches = clauses.map { clause in
                ownerQuestions.first { matchesPrepared(clause, spoken: $0.question) }
            }
            let count = matches.compactMap { $0 }.count
            let stamps = Array(Set(matches.compactMap { $0?.questionTime })).sorted().map { "[" + $0 + "]" }.joined(separator: " ")
            if count == clauses.count && count > 0 { asked.append("- " + question + " " + stamps) }
            else if count > 0 { partial.append("- " + question + " — partial wording match " + stamps) }
            else { notAsked.append("- " + question) }
        }
        var text = "\n\n## From the prep: asked / not asked\n\nCompared with the owner’s detected questions using subject keywords. Unmatched wording needs review; it does not prove the subject was never discussed.\n\n### Asked\n\n"
        text += asked.isEmpty ? "No complete question matches." : asked.joined(separator: "\n")
        if !partial.isEmpty { text += "\n\n### Partly asked\n\n" + partial.joined(separator: "\n") }
        text += "\n\n### Not asked / not matched\n\n" + (notAsked.isEmpty ? "None found." : notAsked.joined(separator: "\n"))
        return text
    }

    static func matchesPrepared(_ prepared: String, spoken: String) -> Bool {
        let stop: Set<String> = ["what", "where", "when", "which", "would", "could", "should", "have", "has", "been", "were", "there", "their", "they", "your", "with", "that", "this", "from", "about", "into", "does", "know", "think", "today", "here", "some", "more", "then", "them", "both", "you", "how", "why", "the", "and", "for", "are", "our", "can", "did", "but", "just", "like", "want", "really"]
        func keywords(_ text: String) -> Set<String> {
            Set(MeetingSource.words(text).filter { $0.count >= 3 && !stop.contains($0) }.map {
                if ["ownership", "own", "owns", "scope"].contains($0) { return "scope" }
                if ["engineering", "eng"].contains($0) { return "engineering" }
                if ["moved", "moving", "brought", "motivations"].contains($0) { return "motivation" }
                return $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0
            })
        }
        let p = MeetingSource.normalized(prepared), q = MeetingSource.normalized(spoken)
        let subjects: [[String]] = [["learning curve"], ["scope", "product org", "ownership split"],
                                  ["motivation", "brought you", "moving over"], ["ai in", "use of ai", "ai product"],
                                  ["api", "webhook"], ["report to", "reporting line"], ["activation moment"],
                                  ["outsourced", "distributed team"]]
        if subjects.contains(where: { group in group.contains(where: p.contains) && group.contains(where: q.contains) }) { return true }
        let wanted = keywords(prepared), heard = keywords(spoken)
        let shared = wanted.intersection(heard).count
        return shared >= 2 && Double(shared) / Double(max(1, wanted.count)) >= 0.45
    }
}
