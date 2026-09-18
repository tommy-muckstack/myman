import Foundation
import GRDB

/// One notes job per meeting, shared by capture and the document window.
/// Only active work is retained; completed notes live in the existing row.
@MainActor
final class MeetingNotesService: ObservableObject {
    typealias Progress = @Sendable (String) async -> Void
    typealias Generate = (String, Date, @escaping Progress) async -> String
    static let shared = MeetingNotesService()

    @Published private(set) var stages: [String: String] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var drafts: [String: String] = [:]
    private var draftTasks: [String: Task<String, Never>] = [:]
    private var draftTimes: [String: Date] = [:]
    private struct Job {
        let token: UUID
        let input: String
        let task: Task<String, Never>
    }
    private var jobs: [String: Job] = [:]
    private var tail: Task<String, Never>?
    private var isShuttingDown = false

    func shutdown() {
        isShuttingDown = true
        jobs.values.forEach { $0.task.cancel() }
        draftTasks.values.forEach { $0.cancel() }
        jobs.removeAll(); draftTasks.removeAll(); tail = nil
        stages.removeAll()
    }
    private let database: DatabaseQueue?
    private let generate: Generate?
    private var db: DatabaseQueue { database ?? Database.shared }

    init(database: DatabaseQueue? = nil,
         generate: Generate? = nil) {
        self.database = database
        self.generate = generate
    }

    /// Start immediately after transcription, without holding up the next
    /// audio job. Local text-model work stays bounded to one meeting at a time.
    @discardableResult func prepare(meetingID: String) -> Task<String, Never>? {
        job(for: meetingID)
    }

    func notes(meetingID: String) async -> String {
        if let task = job(for: meetingID) { return await task.value }
        return (try? await db.read { try Meeting.fetchOne($0, key: meetingID)?.summary }) ?? ""
    }

    func regenerate(meetingID: String) async -> String {
        if let task = job(for: meetingID, replacing: true) { return await task.value }
        return ""
    }

    /// Keep a provisional summary available during capture. Exact source
    /// windows are cached by GroundedMeetingNotes and reused on finalization.
    func updateDraft(_ meeting: Meeting) {
        guard !isShuttingDown, meeting.transcript.count >= 400, draftTasks[meeting.id] == nil,
              Date().timeIntervalSince(draftTimes[meeting.id] ?? .distantPast) >= 120 else { return }
        draftTimes[meeting.id] = Date()
        let previous = tail
        let task = Task { @MainActor [self] in
            defer { draftTasks.removeValue(forKey: meeting.id) }
            _ = await previous?.value
            guard !Task.isCancelled else { return "" }
            let analysis = await Self.generateBounded(meeting)
            guard !Task.isCancelled, !analysis.markdown.isEmpty else { return "" }
            drafts[meeting.id] = analysis.markdown
            if let url = MeetingNotesCache.url(for: meeting)?.deletingPathExtension().appendingPathExtension("draft.md") {
                try? analysis.markdown.write(to: url, atomically: true, encoding: .utf8)
            }
            return analysis.markdown
        }
        draftTasks[meeting.id] = task
        tail = task
    }

    nonisolated static func generateBounded(_ meeting: Meeting, progress: @escaping Progress = { _ in }) async -> MeetingAnalysis {
        do {
            return try await AsyncDeadline.run(seconds: 90) {
                await GroundedMeetingNotes.generate(meeting, progress: progress)
            }
        } catch {
            guard !Task.isCancelled else { return MeetingAnalysis(markdown: "") }
            await progress("Saving notes from the transcript…")
            return await GroundedMeetingNotes.generate(meeting, useLanguageModel: false)
        }
    }

    /// Editing or deleting takes precedence over an in-flight model response.
    func cancel(meetingID: String) {
        jobs.removeValue(forKey: meetingID)?.task.cancel()
        draftTasks.removeValue(forKey: meetingID)?.cancel()
        stages.removeValue(forKey: meetingID)
    }

    private func job(for id: String, replacing: Bool = false) -> Task<String, Never>? {
        guard !isShuttingDown, let meeting = try? db.read({ try Meeting.fetchOne($0, key: id) }),
              (replacing || meeting.summary.isEmpty), !meeting.transcript.isEmpty else { return nil }
        let input = [meeting.transcript, meeting.summary, meeting.kind, meeting.ownerName, meeting.participantsJSON].joined(separator: "\u{0}")
        if let current = jobs[id], current.input == input { return current.task }
        if replacing, !meeting.summary.isEmpty, let url = MeetingNotesCache.url(for: meeting) {
            do {
                let backup = url.deletingLastPathComponent().appendingPathComponent("\(id)-before-notes-\(UUID().uuidString).json")
                try JSONEncoder().encode(meeting).write(to: backup, options: .atomic)
            } catch {
                failures[id] = "Couldn’t preserve the existing notes. Retry when storage is available."
                return nil
            }
        }
        cancel(meetingID: id)
        failures.removeValue(forKey: id)
        let token = UUID()
        let previous = tail
        let queueTimer = MeetingProcessingTimer()
        stages[id] = "Waiting to prepare notes…"
        let task = Task { @MainActor [self] in
            defer {
                if jobs[id]?.token == token {
                    jobs.removeValue(forKey: id)
                    stages.removeValue(forKey: id)
                }
                if jobs.isEmpty && draftTasks.isEmpty { tail = nil }
            }
            _ = await previous?.value
            guard !Task.isCancelled, isCurrent(meeting) else { return "" }
            queueTimer.finish("notes_queue")
            let progress: Progress = { [weak self] stage in
                await self?.setStage(stage, id: id, token: token)
            }
            var analysis = MeetingAnalysis(markdown: "")
            for attempt in 1...3 {
                guard !Task.isCancelled else { return "" }
                if attempt > 1 { await progress("Retrying notes · attempt \(attempt) of 3…") }
                if let generate {
                    analysis = MeetingAnalysis(markdown: await generate(meeting.transcript, meeting.startedAt, progress))
                } else {
                    analysis = await Self.generateBounded(meeting, progress: progress)
                }
                if !analysis.markdown.isEmpty { break }
            }
            let generated = analysis.markdown
            guard !Task.isCancelled else { return "" }
            guard !generated.isEmpty else {
                failures[id] = "Notes could not be generated. Your transcript is saved."
                return ""
            }
            do {
                let saved: Meeting? = try await db.write { [analysis] db in
                    // Field-only, conditional update: never overwrite edits,
                    // resurrect a deletion, or save notes for an old transcript.
                    try db.execute(sql: """
                        UPDATE meeting SET summary = ?, analysisJSON = ?
                        WHERE id = ? AND summary = ? AND transcript = ?
                            AND kind = ? AND ownerName = ? AND participantsJSON = ?
                        """, arguments: [generated, String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self), id, meeting.summary, meeting.transcript,
                                          meeting.kind, meeting.ownerName, meeting.participantsJSON])
                    guard db.changesCount == 1 else { return nil }
                    try TaskHygiene.store(analysis.actions, meeting: meeting, in: db)
                    try MeetingVocabulary.record(meeting, in: db)
                    return try Meeting.fetchOne(db, key: id)
                }
                guard let saved else { return "" }
                if database == nil {
                    TasksStore.shared.refresh()
                    Brain.syncMeeting(id: saved.id, title: saved.title,
                                      startedAt: saved.startedAt, endedAt: saved.endedAt,
                                      summary: saved.summary, transcript: saved.transcript)
                }
                return saved.summary
            } catch {
                NSLog("My Man [Summary] could not save notes")
                failures[id] = "Notes could not be saved. Retry when ready."
                return ""
            }
        }
        jobs[id] = Job(token: token, input: input, task: task)
        tail = task
        return task
    }

    private func isCurrent(_ meeting: Meeting) -> Bool {
        guard let current = try? db.read({ try Meeting.fetchOne($0, key: meeting.id) }) else { return false }
        return current.summary == meeting.summary && current.transcript == meeting.transcript
            && current.kind == meeting.kind && current.ownerName == meeting.ownerName
            && current.participantsJSON == meeting.participantsJSON
    }

    private func setStage(_ stage: String, id: String, token: UUID) {
        guard jobs[id]?.token == token else { return }
        stages[id] = stage
    }
}

/// Monotonic, content-free timings make slow stages diagnosable on each Mac.
struct MeetingProcessingTimer {
    private let start = ProcessInfo.processInfo.systemUptime
    func finish(_ stage: String) {
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        Analytics.track("meeting_processing_stage", ["stage": stage, "duration_ms": milliseconds])
        NSLog("My Man [Meeting processing] %@: %d ms", stage, milliseconds)
    }
}
