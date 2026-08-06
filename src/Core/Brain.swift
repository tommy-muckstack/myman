import AppKit
import Foundation

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
            for sub in ["notes", "meetings", "screenshots", "recordings"] {
                try? fm.createDirectory(at: root.appendingPathComponent(sub),
                                        withIntermediateDirectories: true)
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
            - `tasks.md` — your open and completed tasks
            - `people.md` — teammates learned from recorded meetings
            - `vocabulary.md` — proper nouns that tune dictation
            """
            try? readme.write(to: root.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
            let agents = """
            # My Man Brain — agent instructions

            Canonical, auto-synced record of the user's My Man captures.
            `notes/` (frontmatter + markdown), `meetings/` (summary + speaker
            transcript), `recordings/` (screen-recording transcripts;
            frontmatter `file:` is the video path), `screenshots/` (frontmatter
            `file:` is the image path; body is OCR'd text), `tasks.md`
            (- [ ] checklist), `people.md` (who the user meets with, ranked),
            `vocabulary.md` (dictation proper nouns — adding terms improves
            speech-to-text).

            Signal hierarchy — weigh sources accordingly when answering:
            1. `meetings/` — highest signal: deliberate, speaker-attributed
               conversations with summaries.
            2. `notes/` — deliberate writing, terse but intentional.
            3. `recordings/` — medium: narration/audio of what the user was
               demonstrating on screen.
            4. `screenshots/` — lowest signal, ambient context: whatever
               happened to be on screen. Use to corroborate, not to lead.

            Sync is one-way app → brain: read freely, write only when asked,
            never delete. Timestamps ISO-8601 UTC.
            """
            try? agents.write(to: root.appendingPathComponent("CLAUDE.md"),
                              atomically: true, encoding: .utf8)
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
            var content = """
            ---
            id: \(id)
            started: \(iso(startedAt))
            ended: \(endedAt.map(iso) ?? "")
            ---

            # \(title)

            """
            if !summary.isEmpty { content += "\(summary)\n\n" }
            if !transcript.isEmpty { content += "## Transcript\n\n\(transcript)\n" }
            write(content, to: "meetings/\(day(startedAt))-\(id.prefix(8)).md")
        }
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
    /// and any whose OCR never finished (app quit mid-analysis) gets
    /// re-OCR'd first — the guarantee is EVERY screenshot, with its text.
    static func backfillScreenshots() {
        Task.detached(priority: .background) {
            let shots: [Screenshot] = (try? await Database.shared.read { db in
                try Screenshot.fetchAll(db)
            }) ?? []
            for shot in shots {
                var ocrText = shot.ocrText
                if ocrText.isEmpty, FileManager.default.fileExists(atPath: shot.path),
                   let image = NSImage(contentsOfFile: shot.path) {
                    let analysis = await ImageAnalysis.analyze(image)
                    ocrText = analysis.searchableText
                    if !ocrText.isEmpty {
                        let completedOCR = ocrText
                        try? await Database.shared.write { db in
                            try db.execute(sql: "UPDATE screenshot SET ocrText = ? WHERE id = ?",
                                           arguments: [completedOCR, shot.id])
                        }
                        if let blob = SearchService.embedding(for: completedOCR) {
                            try? await Database.shared.write { db in
                                try db.execute(sql: "UPDATE screenshot SET embedding = ? WHERE id = ?",
                                               arguments: [blob, shot.id])
                            }
                        }
                        syncScreenshot(id: shot.id, filePath: shot.path,
                                       ocrText: completedOCR, createdAt: shot.createdAt)
                        continue
                    }
                }
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

    private static func write(_ content: String, to relativePath: String) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
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
        let paths = ["README.md", "CLAUDE.md", "notes", "meetings", "screenshots", "recordings",
                     "tasks.md", "people.md", "vocabulary.md"]
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

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
