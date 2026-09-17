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

    /// Only an explicitly linked local Markdown prep file. Remote documents
    /// require their own access integration; never search unrelated files.
    @MainActor static func capture(for meeting: Meeting) {
        guard isInterview(meeting.title), EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let destination = url(for: meeting) else { return }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: meeting.startedAt.addingTimeInterval(-1200),
                                                                    end: meeting.startedAt.addingTimeInterval(1200), calendars: nil))
        let matches = events.filter { $0.title == meeting.title }
        guard matches.count == 1, let notes = matches.first?.notes,
              let expression = try? NSRegularExpression(pattern: #"file://[^\s<>\")]+\.md"#),
              let match = expression.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range, in: notes), let file = URL(string: String(notes[range])), file.isFileURL,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
              let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let questions = content.components(separatedBy: .newlines).filter { $0.contains("?") && !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- *\t")) }
        let context = Self(prepPath: file.path, questions: Array(questions.prefix(50)))
        try? JSONEncoder().encode(context).write(to: destination, options: .atomic)
    }

    static func unmatchedQuestions(for meeting: Meeting) -> String {
        guard let url = url(for: meeting), let data = try? Data(contentsOf: url),
              let context = try? JSONDecoder().decode(Self.self, from: data) else { return "" }
        let spoken = MeetingSource.parse(meeting.transcript).map { Set(MeetingSource.words($0.text).filter { $0.count > 3 }) }
        let unmatched = context.questions.filter { question in
            let words = Set(MeetingSource.words(question).filter { $0.count > 3 })
            return words.count >= 3 && !spoken.contains { Double(words.intersection($0).count) / Double(words.count) >= 0.6 }
        }
        guard !unmatched.isEmpty else { return "" }
        return "\n\n## Prepared questions to review\n\nThese questions from the linked prep file were not matched by wording; review whether the discussion answered them indirectly.\n\n" + unmatched.map { "- " + $0 }.joined(separator: "\n")
    }
}
