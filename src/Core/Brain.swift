import AppKit
import Foundation
import GRDB
import CryptoKit

// The user's brain: a plain folder of markdown files mirroring everything
// My Man captures — notes, meeting summaries + transcripts, tasks. It's a
// git repo from birth, so it ports to GitHub / another machine / any LLM
// with zero lock-in. Files are the source of portability; the SQLite DB
// stays the app's working store.

enum Brain {
    // Home root, tommy-brain style — and unlike ~/Documents, no TCC prompt.
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MyManBrain", isDirectory: true)
    }

    private static let queue = DispatchQueue(label: "com.muckstack.myman.brain", qos: .utility)

    /// Create the folder skeleton + git repo on first run.
    static func bootstrap() {
        queue.async {
            let fm = FileManager.default
            let existed = fm.fileExists(atPath: root.path)
            for sub in ["notes", "meetings", "screenshots", "recordings", "dictations", "task-items", "themes"] {
                try? fm.createDirectory(at: root.appendingPathComponent(sub),
                                        withIntermediateDirectories: true)
            }
            if let companion = Bundle.module.url(forResource: "BrainCompanion", withExtension: nil) {
                for file in (try? fm.contentsOfDirectory(at: companion, includingPropertiesForKeys: nil)) ?? [] {
                    if let data = try? Data(contentsOf: file) { try? writeAgentData(data, to: "tools/" + file.lastPathComponent) }
                }
            }
            // Docs regenerate every launch — the brain's map must never lag
            // behind what the app actually syncs.
            let readme = """
            # My Man Brain

            Everything you capture with My Man, as plain markdown — notes,
            meetings, screenshots, tasks, and the people you meet with. This
            folder is a git repo: push it to GitHub to sync it across
            machines, or point any LLM at it.

            - `notes/` — one file per note
            - `meetings/` — one file per recorded meeting (summary + speaker transcript + slide paths)
            - `screenshots/` — one file per screenshot (OCR text + path to the image)
            - `recordings/` — one file per screen recording (transcript + path to the video)
            - `dictations/` — dictated text with capture times
            - `task-items/` — complete task details and dates, including completed tasks
            - `themes/` — saved MyMan Themes and their source items
            - `catalog.json` — current allowlist, metadata, meeting links, tags, local times, and thumbnail references
            - `tools/cli.mjs` — bundled, read-only query companion (Node.js 22+; no npm install needed)
            - `tools/server.mjs` — the same tools over local stdio MCP

            From this folder, run `node tools/cli.mjs --root "$PWD" screenshots --meeting "Jared demo"`.
            Add `--exclude-tag slide-deck`, `--app Chrome`, `--tag web-app`, or `--unique` as needed.
            For a time range, use `--after 2026-09-01T00:00:00-04:00 --before 2026-09-02T00:00:00-04:00`.
            Run `node tools/cli.mjs --root "$PWD" status` or `--help` to discover other commands.
            Ambiguous meeting descriptions return candidates instead of choosing a call silently.
            Screenshots are primary evidence for visual/design reference; inspect thumbnails or originals.
            Tags and sensitivity hints are heuristics, not evidence that reuse is authorized or safe.
            - `tasks.md` — your open and completed tasks
            - `people.md` — teammates learned from recorded meetings
            - `vocabulary.md` — proper nouns that tune dictation
            """
            try? readme.write(to: root.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
            let agents = """
            # My Man Brain — agent instructions

            Canonical, auto-synced record of the user's My Man captures.
            The companion ships here: `node tools/cli.mjs --root "$PWD" --help` (Node.js 22+).
            Start with `screenshots --meeting "Jared demo" --exclude-tag slide-deck` for visual retrieval.
            `--meeting` accepts a meeting ID, export path, or description; ambiguous matches return candidates.
            Use `image '{"path":"screenshots/returned-file.md","size":"thumbnail"}'` for a compact visual preview.
            Screenshots carry explicit meeting links, local timestamps, OCR, and best-effort tags/sensitivity hints.
            App/window/URL fields are present only when captured with the user's optional metadata setting.
            Use the Brain companion's `collect` tool for time ranges, types,
            people, keywords/phrases, and saved Themes. Follow every pagination
            cursor and read full source documents for comprehensive summaries.
            `catalog.json` is the current allowlist; old or excluded files may
            remain in this user-owned folder or its git history. Respect that
            allowlist. `dictations/`, `task-items/`, and `themes/` extend the
            capture exports with dictated text, complete tasks, and saved Themes.
            Inferred themes in your answer are distinct from saved app Themes.
            `notes/` (frontmatter + markdown), `meetings/` (summary + speaker
            transcript), `recordings/` (screen-recording transcripts;
            frontmatter `file:` is the video path), `screenshots/` (frontmatter
            `file:` is the image path, `ocr_text:` contains full OCR, and the body is a short description), `tasks.md`
            (- [ ] checklist), `people.md` (who the user meets with, ranked),
            `vocabulary.md` (dictation proper nouns — adding terms improves
            speech-to-text).

            Choose sources according to the task. For factual summaries:
            1. `meetings/` — highest signal: deliberate, speaker-attributed
               conversations with summaries.
            2. `notes/` — deliberate writing, terse but intentional.
            3. `recordings/` — medium: narration/audio of what the user was
               demonstrating on screen.
            4. `screenshots/` — OCR can corroborate discussion, but does not establish what someone said.

            For design references, UI comparisons, slides, or "what did it look like," screenshots are
            the primary source. Use `screenshots`, meeting links, tags, and thumbnail/original image tools.
            Near-duplicate sequences help triage; use all originals when small visual changes matter.
            Sensitivity hints are best-effort. `not_detected` does not mean public or safe to reuse.
            A meeting link establishes recording context/time overlap, not subject-matter relevance.

            Sync is one-way app → brain: read freely, write only when asked,
            never delete. UTC timestamps have local-time and timezone companions. For legacy captures,
            timezone_source=export_mac identifies the exporting Mac's timezone, not a known historical location.
            """
            try? agents.write(to: root.appendingPathComponent("CLAUDE.md"),
                              atomically: true, encoding: .utf8)
            try? agents.write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            if !existed {
                git("init")
                stageManagedFiles()
                git("commit", "-m", "My Man brain: first sync")
            }
        }
    }

    // MARK: Links (for pointing LLMs/agents at a capture)

    nonisolated static func meetingFilePath(id: String, startedAt: Date) -> String {
        root.appendingPathComponent("meetings/\(day(startedAt))-\(id.prefix(8)).md").path
    }

    nonisolated static func noteFilePath(id: String, createdAt: Date) -> String {
        root.appendingPathComponent("notes/\(day(createdAt))-\(id.prefix(8)).md").path
    }

    // MARK: Sync

    static func syncNote(id: String, title: String, body: String,
                         createdAt: Date, updatedAt: Date) {
        queue.async {
            guard let current = try? Database.shared.read({ try Note.fetchOne($0, key: id) }), current.body == body, current.title == title else { return }
            let content = """
            ---
            id: \(id)
            created: \(iso(createdAt))
            updated: \(iso(updatedAt))
            ---

            # \(title.isEmpty ? "Untitled" : title)

            \(body)
            """
            write(content, to: "notes/\(day(createdAt))-\(id.prefix(8)).md")
        }
    }

    static func deleteNote(id: String, createdAt: Date) {
        queue.async {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("notes/\(day(createdAt))-\(id.prefix(8)).md"))
            commitSoon()
        }
    }

    static func syncMeeting(id: String, title: String, startedAt: Date,
                            endedAt: Date?, summary: String, transcript: String) {
        queue.async {
            guard let current = try? Database.shared.read({ try Meeting.fetchOne($0, key: id) }), current.transcript == transcript, current.summary == summary, current.title == title else { return }
            let content = meetingMarkdown(current)
            write(content, to: "meetings/\(day(startedAt))-\(id.prefix(8)).md")
        }
    }

    static func meetingMarkdown(_ meeting: Meeting) -> String {
        let participants = speakers(in: meeting.transcript).map { label in
            let name = label == "You" ? (meeting.ownerName.isEmpty ? NSFullUserName() : meeting.ownerName) : label
            let matches = meeting.participants.filter {
                $0.name == name || ($0.name.split(separator: " ").first.map(String.init) == name)
                    || (label == "You" && $0.isOwner)
            }
            guard matches.count == 1, let person = matches.first else { return name }
            return person.name + (person.email.map { " <\($0)>" } ?? "")
        }
        let lowContent = !meeting.transcript.isEmpty && meeting.transcript.split(whereSeparator: \.isWhitespace).count < 100
        var content = """
        ---
        id: \(meeting.id)
        kind: \(meeting.captureKind.rawValue)
        started: \(iso(meeting.startedAt))
        ended: \(meeting.endedAt.map(iso) ?? "")
        participants:
        \(yamlList(participants))\(lowContent ? "\nlow_content: true" : "")
        ---

        # \(meeting.title)

        """
        if !meeting.summary.isEmpty { content += "\(meeting.summary)\n\n" }
        if !meeting.transcript.isEmpty { content += "## Transcript\n\n\(meeting.transcript)\n" }
        return content
    }

    /// Who spoke, in first-appearance order, read back out of the transcript
    /// itself. Deriving it here rather than at the five call sites means the
    /// list can never drift from the labels actually in the file — including
    /// after a rename from the speaker legend.
    nonisolated static func speakers(in transcript: String) -> [String] {
        // Either the interleaved form (**Name** [m:ss]:) or the older
        // two-block form (You:). The bare-label branch is deliberately narrow
        // — a name, not any sentence that happens to contain a colon.
        let pattern = #"(?m)^(?:\*\*([^*\n]{1,80})\*\*\s*\[\d+:\d{2}\]|([A-Za-z][A-Za-z0-9 .'\-]{0,39})):"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: transcript,
                                   range: NSRange(transcript.startIndex..., in: transcript)) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let range = Range(match.range(at: group), in: transcript) else { continue }
            let label = String(transcript[range]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if seen.insert(label).inserted { ordered.append(label) }
        }
        return ordered
    }

    /// A YAML block sequence, or `[]` when there is nothing to list.
    private static func yamlList(_ items: [String]) -> String {
        guard !items.isEmpty else { return "  []" }
        return items.map { "  - " + String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) }
            .joined(separator: "\n")
    }

    /// Tasks live in one checklist file, fully regenerated each sync.
    static func syncTasks(open: [(title: String, source: String, createdAt: Date)],
                          done: [(title: String, source: String, completedAt: Date?)]) {
        queue.async {
            var content = "# Tasks\n\n"
            for task in open {
                content += "- [ ] \(task.title)  <!-- \(task.source), \(day(task.createdAt)) -->\n"
            }
            if !done.isEmpty {
                content += "\n## Done\n\n"
                for task in done.prefix(100) {
                    content += "- [x] \(task.title)  <!-- \(task.source)\(task.completedAt.map { ", \(day($0))" } ?? "") -->\n"
                }
            }
            write(content, to: "tasks.md")
        }
    }

    static func syncScreenshot(id: String, filePath: String, ocrText: String,
                               createdAt: Date) {
        queue.async {
            guard let current = try? Database.shared.read({ try Screenshot.fetchOne($0, key: id) }), current.ocrText == ocrText else { return }
            let content = """
            ---
            id: \(id)
            file: \(filePath)
            captured: \(iso(createdAt))
            ---

            # Screenshot \(day(createdAt))

            \(ocrText.isEmpty ? "(no text detected)" : ocrText)
            """
            write(content, to: "screenshots/\(day(createdAt))-\(id.prefix(8)).md")
        }
    }

    static func deleteScreenshot(id: String, createdAt: Date) {
        queue.async {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("screenshots/\(day(createdAt))-\(id.prefix(8)).md"))
            commitSoon()
        }
    }

    static func deleteMeeting(id: String, startedAt: Date) {
        queue.async {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("meetings/\(day(startedAt))-\(id.prefix(8)).md"))
            commitSoon()
        }
    }

    /// Catch-up at launch: any screenshot missing its brain file gets one,
    /// while OCRStore separately resumes incomplete image analysis.
    static func backfillScreenshots() {
        Task.detached(priority: .background) {
            let shots: [Screenshot] = (try? await Database.shared.read { db in
                try Screenshot.fetchAll(db)
            }) ?? []
            for shot in shots {
                // OCRStore owns recognition, version checks and geometry.
                // Export existing text here; refreshed OCR schedules its own export.
                let ocrText = shot.ocrText
                let file = root.appendingPathComponent(
                    "screenshots/\(day(shot.createdAt))-\(shot.id.prefix(8)).md")
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                syncScreenshot(id: shot.id, filePath: shot.path,
                               ocrText: ocrText, createdAt: shot.createdAt)
            }
        }
    }

    static func syncRecording(id: String, filePath: String, duration: Int,
                              transcript: String, createdAt: Date) {
        queue.async {
            guard let current = try? Database.shared.read({ try ScreenRecording.fetchOne($0, key: id) }), current.transcript == transcript else { return }
            let content = """
            ---
            id: \(id)
            file: \(filePath)
            duration_seconds: \(duration)
            captured: \(iso(createdAt))
            ---

            # Screen recording \(day(createdAt))

            \(transcript.isEmpty ? "(no speech detected)" : transcript)
            """
            write(content, to: "recordings/\(day(createdAt))-\(id.prefix(8)).md")
        }
    }

    static func deleteRecording(id: String, createdAt: Date) {
        queue.async {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("recordings/\(day(createdAt))-\(id.prefix(8)).md"))
            commitSoon()
        }
    }

    static func syncPeople(_ markdown: String) {
        queue.async {
            write(markdown, to: "people.md")
        }
    }

    // MARK: Plumbing (all on `queue`)

    private static var pendingAgentExport: DispatchWorkItem?
    private static var writtenHashes: [String: SHA256.Digest] = [:]
    static func scheduleAgentExport() {
        queue.async {
            pendingAgentExport?.cancel()
            let work = DispatchWorkItem {
                do {
                    let source = try Database.shared.read { try BrainAgentExport.source(in: $0) }
                    let snapshot = BrainAgentExport.snapshot(source: source)
                    let previous = (try? Data(contentsOf: root.appendingPathComponent("catalog.json")))
                        .flatMap { try? JSONDecoder().decode(BrainAgentExport.Catalog.self, from: $0) }
                    // The catalog is written last. A failed export never claims
                    // newly generated evidence is available to an agent.
                    for (path, content) in snapshot.documents { try writeAgentFile(content, to: path) }
                    for (path, data) in snapshot.assets { try writeAgentData(data, to: path) }
                    let thumbnails = root.appendingPathComponent("assets/capture-thumbnails")
                    let ownedDirectory = thumbnails.resolvingSymlinksInPath().path == thumbnails.standardizedFileURL.path
                    for file in (ownedDirectory ? try? FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil) : nil) ?? [] {
                        guard file.pathExtension == "png", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                        let path = "assets/capture-thumbnails/" + file.lastPathComponent
                        if snapshot.assets[path] == nil {
                            try? FileManager.default.removeItem(at: file)
                            writtenHashes.removeValue(forKey: path)
                        }
                    }
                    let current = Set(snapshot.documents.keys)
                    for entry in previous?.exports ?? [] where !current.contains(entry.path) {
                        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                        guard parts.count == 2, ["dictations", "task-items", "themes"].contains(String(parts[0])),
                              String(parts[1]).range(of: #"^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Fa-f0-9]{8}|[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12})\.md$"#, options: .regularExpression) != nil else { continue }
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))
                        writtenHashes.removeValue(forKey: entry.path)
                    }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(snapshot.catalog)
                    try data.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
                    commitSoon()
                } catch { NSLog("Man: agent export will retry after the next change: %@", error.localizedDescription) }
            }
            pendingAgentExport = work
            queue.asyncAfter(deadline: .now() + 0.75, execute: work)
        }
    }

    private static func writeAgentFile(_ content: String, to relativePath: String) throws {
        try writeAgentData(Data(content.utf8), to: relativePath)
    }

    private static func writeAgentData(_ data: Data, to relativePath: String) throws {
        let hash = SHA256.hash(data: data)
        let url = root.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if writtenHashes[relativePath] == hash && FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        writtenHashes[relativePath] = hash
    }

    private static func write(_ content: String, to relativePath: String) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        writtenHashes.removeValue(forKey: relativePath)
        commitSoon()
    }

    /// Debounced auto-commit so the repo history stays meaningful, not noisy.
    private static var pendingCommit: DispatchWorkItem?
    private static func commitSoon() {
        pendingCommit?.cancel()
        let work = DispatchWorkItem {
            // Stage only files owned by My Man. The Brain is intentionally a
            // user-visible folder, so unrelated work must never be committed
            // by an automatic sync.
            stageManagedFiles()
            git("commit", "-m", "brain sync")
        }
        pendingCommit = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }

    @discardableResult
    private static func git(_ args: String...) -> Int32 {
        git(args)
    }

    /// Only stage paths that currently exist. `git add` treats a missing
    /// pathspec as an error, and not every optional Brain artifact exists on
    /// a user's first launch.
    private static func stageManagedFiles() {
        let paths = ["README.md", "CLAUDE.md", "AGENTS.md", "tools", "notes", "meetings", "screenshots", "recordings",
                     "tasks.md", "people.md", "vocabulary.md", "assets", "dictations", "task-items", "themes", "catalog.json"]
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard !paths.isEmpty else { return }
        _ = git(["add", "-A", "--"] + paths)
    }

    @discardableResult
    private static func git(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
