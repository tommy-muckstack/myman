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
        Array(content.components(separatedBy: .newlines).compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let clean = line.replacingOccurrences(of: #"^\s*(?:[-*]|\d+[.)])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let lower = MeetingSource.normalized(clean)
            guard clean.contains("?") || ["how ", "what ", "why ", "where ", "when "].contains(where: lower.hasPrefix) else { return nil }
            return clean
        }.prefix(50))
    }

    static func unmatchedQuestions(for meeting: Meeting) -> String {
        let saved = url(for: meeting).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        guard let context = saved ?? discover(for: meeting) else { return "" }
        let spoken = MeetingSource.paragraphs(MeetingSource.parse(meeting.transcript)).map { Set(MeetingSource.words($0.text).filter { $0.count > 3 }) }
        let unmatched = context.questions.filter { question in
            let words = Set(MeetingSource.words(question).filter { $0.count > 3 })
            return words.count >= 3 && !spoken.contains { Double(words.intersection($0).count) / Double(words.count) >= 0.6 }
        }
        guard !unmatched.isEmpty else { return "" }
        return "\n\n## Prepared questions to review\n\nThese questions from the linked prep file were not matched by wording; review whether the discussion answered them indirectly.\n\n" + unmatched.map { "- " + $0 }.joined(separator: "\n")
    }
}
