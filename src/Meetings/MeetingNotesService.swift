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
    private struct Job {
        let token: UUID
        let transcript: String
        let task: Task<String, Never>
    }
    private var jobs: [String: Job] = [:]
    private var tail: Task<String, Never>?
    private let database: DatabaseQueue?
    private let generate: Generate
    private var db: DatabaseQueue { database ?? Database.shared }

    init(database: DatabaseQueue? = nil,
         generate: @escaping Generate = { text, date, progress in
             await MeetingSummarizer.summarize(text, meetingDate: date, progress: progress)
         }) {
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

    /// Editing or deleting takes precedence over an in-flight model response.
    func cancel(meetingID: String) {
        jobs.removeValue(forKey: meetingID)?.task.cancel()
        stages.removeValue(forKey: meetingID)
    }

    private func job(for id: String) -> Task<String, Never>? {
        guard let meeting = try? db.read({ try Meeting.fetchOne($0, key: id) }),
              meeting.summary.isEmpty, !meeting.transcript.isEmpty else { return nil }
        if let current = jobs[id], current.transcript == meeting.transcript { return current.task }
        cancel(meetingID: id)
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
                if jobs.isEmpty { tail = nil }
            }
            _ = await previous?.value
            guard !Task.isCancelled, isCurrent(meeting) else { return "" }
            queueTimer.finish("notes_queue")
            let generated = await generate(meeting.transcript, meeting.startedAt) { [weak self] stage in
                await self?.setStage(stage, id: id, token: token)
            }
            guard !Task.isCancelled, !generated.isEmpty else { return "" }
            do {
                let saved: Meeting? = try await db.write { db in
                    // Field-only, conditional update: never overwrite edits,
                    // resurrect a deletion, or save notes for an old transcript.
                    try db.execute(sql: """
                        UPDATE meeting SET summary = ?
                        WHERE id = ? AND summary = '' AND transcript = ?
                        """, arguments: [generated, id, meeting.transcript])
                    guard db.changesCount == 1 else { return nil }
                    return try Meeting.fetchOne(db, key: id)
                }
                guard let saved else { return "" }
                if database == nil {
                    Brain.syncMeeting(id: saved.id, title: saved.title,
                                      startedAt: saved.startedAt, endedAt: saved.endedAt,
                                      summary: saved.summary, transcript: saved.transcript)
                }
                return saved.summary
            } catch {
                NSLog("My Man [Summary] could not save notes")
                return ""
            }
        }
        jobs[id] = Job(token: token, transcript: meeting.transcript, task: task)
        tail = task
        return task
    }

    private func isCurrent(_ meeting: Meeting) -> Bool {
        guard let current = try? db.read({ try Meeting.fetchOne($0, key: meeting.id) }) else { return false }
        return current.summary.isEmpty && current.transcript == meeting.transcript
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
