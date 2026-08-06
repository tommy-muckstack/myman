import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// On-device task extraction (Apple Foundation Models, macOS 26+). The bar
// varies by source: meetings are high-signal so probable action items count;
// notes similar; dictation is mostly prose so ONLY explicit commitments pass.
// Below macOS 26 this is a no-op — no cloud fallback, by design.

enum TaskExtractor {
    enum Source: String {
        case meeting, note, dictation

        var maxTasks: Int {
            switch self {
            case .meeting: return 4
            case .note: return 3
            case .dictation: return 1
            }
        }

        /// Below this the text can't contain a real commitment — skip the
        /// model entirely (kills "testing testing" hallucinations).
        var minChars: Int {
            switch self {
            case .meeting: return 200
            case .note: return 30
            case .dictation: return 20
            }
        }

        /// Dictation only runs extraction when the speaker uses explicit
        /// task language — no trigger phrase, no model call, no task.
        static let dictationTriggers = [
            "make a task", "create a task", "add a task", "add to my list",
            "remind me to", "reminder to", "don't forget to", "dont forget to",
            "i need to", "need to remember", "follow up with", "i'll follow up",
            "to-do", "todo",
        ]

        /// The bar is FIRST-PERSON COMMITMENT for every source. A topic being
        /// discussed is never a task; every candidate must cite its evidence.
        var barInstruction: String {
            switch self {
            case .meeting:
                return """
                    Only extract a task when a speaker EXPLICITLY commits in first \
                    person: "I will…", "I'll…", "I'm going to…", "I need to…", "my \
                    action item is…", "remind me to…". Topics discussed, ideas, \
                    suggestions, questions, other people's obligations, and things \
                    that merely SHOULD happen are NOT tasks — answer NONE for those.
                    """
            case .note:
                return """
                    Only extract explicitly written to-dos: checklist lines, "TODO", \
                    "need to…", "don't forget…", imperative reminders the writer left \
                    for themselves. Topics, facts, and prose are NOT tasks — answer \
                    NONE for those.
                    """
            case .dictation:
                return """
                    Only extract a task from EXPLICIT task language: "make a task", "create \
                    a task", "remind me to", "don't forget to", "I need to", "I'll follow \
                    up". Anything else — descriptions, opinions, test phrases, casual \
                    mentions — is NOT a task; answer NONE.
                    """
            }
        }
    }

    /// Extract and store tasks. Fire-and-forget; posts a toast when found.
    static func run(text: String, source: Source) {
        guard text.count >= source.minChars else { return }
        if source == .dictation {
            let lowered = text.lowercased()
            guard Source.dictationTriggers.contains(where: lowered.contains) else { return }
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        Task { @MainActor in
            let titles = await extract(text: text, source: source)
            guard !titles.isEmpty else { return }
            let added = TasksStore.shared.addExtracted(titles, source: source.rawValue)
            if added > 0 {
                Toast.show(added == 1
                    ? "Added a task from your \(source.rawValue)"
                    : "Added \(added) tasks from your \(source.rawValue)",
                    systemImage: "checklist")
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func extract(text: String, source: Source) async -> [String] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }
        let session = LanguageModelSession(instructions: """
            You extract personal action items from text. \(source.barInstruction)
            Reply with at most \(source.maxTasks) tasks, one per line, each line \
            starting with "- ", phrased as a short imperative (max 12 words). \
            Each line must end with " | " followed by the EXACT words from the \
            text that commit to the task, quoted verbatim. \
            If there are no qualifying tasks reply with exactly: NONE
            """)
        do {
            let response = try await session.respond(to: String(text.prefix(6000)))
            let content = response.content
            guard !content.localizedCaseInsensitiveContains("NONE") || content.contains("- ") else {
                return []
            }
            var titles: [String] = []
            let haystack = text.lowercased()
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                let body = String(trimmed.dropFirst(2))
                // Evidence gate, ALL sources: the cited quote must literally
                // appear in the text, or the task is a fabrication — drop it.
                let parts = body.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let quote = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
                    .lowercased()
                guard quote.count > 10, haystack.contains(quote) else { continue }
                titles.append(parts[0].trimmingCharacters(in: .whitespaces))
                if titles.count == source.maxTasks { break }
            }
            return titles
        } catch {
            NSLog("My Man [Tasks] extraction failed: \(error)")
            return []
        }
    }
    #endif
}
