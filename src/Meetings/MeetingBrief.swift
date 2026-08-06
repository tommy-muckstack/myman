import Foundation

/// Builds an editable, unsaved pre-meeting brief from calendar metadata and
/// local Brain context. It never writes until the user saves the note editor.
enum MeetingBrief {
    static func make(for event: CalendarPanelView.EventLite) async -> String {
        let query = ([event.title] + event.attendeeNames).joined(separator: " ")
        let hits = await Task.detached(priority: .userInitiated) {
            SearchService.search(query, limit: 5).map(source)
        }.value
        let people = People.all().filter { person in
            event.attendeeNames.contains { $0.localizedCaseInsensitiveContains(person.name) || person.name.localizedCaseInsensitiveContains($0) }
        }

        var brief = "# Brief: \(event.title)\n\n"
        brief += "**When:** \(event.start.formatted(date: .abbreviated, time: .shortened))"
        brief += "–\(event.end.formatted(date: .omitted, time: .shortened))\n"
        if !event.attendeeNames.isEmpty {
            brief += "**Attendees:** \(event.attendeeNames.joined(separator: ", "))\n"
        }
        if !event.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brief += "\n## Calendar context\n\n\(event.notes)\n"
        }
        if !people.isEmpty {
            brief += "\n## Your history\n\n"
            for person in people.prefix(5) {
                brief += "- \(person.name): \(person.meetCount) prior meeting\(person.meetCount == 1 ? "" : "s"), last met \(person.lastMetAt.formatted(date: .abbreviated, time: .omitted))\n"
            }
        }
        if !hits.isEmpty {
            brief += "\n## Relevant context\n\n" + hits.joined(separator: "\n\n") + "\n"
        }
        brief += "\n## Questions to consider\n\n- What outcome would make this meeting successful?\n- What decision or next step should be clear by the end?\n"
        return brief
    }

    private static func source(_ hit: SearchHit) -> String {
        switch hit {
        case .note(let note): return "- **Note — \(note.title):** \(note.body.prefix(350).replacingOccurrences(of: "\n", with: " "))"
        case .meeting(let meeting): return "- **Meeting — \(meeting.title):** \((meeting.summary.isEmpty ? meeting.transcript : meeting.summary).prefix(350).replacingOccurrences(of: "\n", with: " "))"
        case .screenshot(let shot): return "- **Screenshot:** \(shot.ocrText.prefix(250).replacingOccurrences(of: "\n", with: " "))"
        case .recording(let recording): return "- **Recording — \(recording.title):** \(recording.transcript.prefix(250).replacingOccurrences(of: "\n", with: " "))"
        case .dictation(let dictation): return "- **Dictation:** \(dictation.text.prefix(250).replacingOccurrences(of: "\n", with: " "))"
        }
    }
}
