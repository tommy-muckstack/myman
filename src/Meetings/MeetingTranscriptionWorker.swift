import Foundation

/// Final transcripts have their own speech models. The controller serializes
/// jobs; recording, live transcription, and dictation never use this engine.
actor MeetingTranscriptionWorker {
    private let service = TranscriptionService()

    func process(_ job: MeetingController.TranscriptionJob) async throws -> MeetingTranscriptResult {
        let timer = MeetingProcessingTimer()
        // Qwen's stateful Core ML decoder can abort the process when its
        // IOSurface allocation fails. Swift cannot catch that exception.
        // Meetings use the same bounded, stateless engine as live captions.
        let candidates = job.candidates.isEmpty ? MeetingController.speakerCandidates(eventTitle: job.record.title, attendees: job.record.participants.filter { !$0.isOwner }.map(\.name)) : job.candidates
        let reader = LiveMeetingTranscriptReader(
            micURL: job.micPath.map { URL(fileURLWithPath: $0) },
            systemURL: job.systemPath.map { URL(fileURLWithPath: $0) },
            singleRemote: candidates.fromAttendees && candidates.names.count == 1,
            micLag: job.micLag,
            checkpointURL: MeetingTranscriptCheckpoint.url(micPath: job.micPath, systemPath: job.systemPath,
                                                           regenerating: job.regenerating),
            wallDuration: job.record.endedAt.map { $0.timeIntervalSince(job.record.startedAt) }, contextMeeting: job.record)
        try await reader.prepare()
        while await reader.hasUnreadAudio() {
            try Task.checkCancellation()
            _ = try await reader.next(final: true)
        }
        let turns = await reader.savedTurns()
        if !job.record.liveCorrections.isEmpty, !service.isReady { await service.load(kind: .parakeet) }
        timer.finish("speech_model_ready")
        let result = await MeetingController.buildTranscriptResult(
            micPath: job.micPath, systemPath: job.systemPath,
            candidates: candidates, corrections: job.record.liveCorrections,
            wallDuration: job.record.endedAt.map { $0.timeIntervalSince(job.record.startedAt) },
            micLag: job.micLag, title: job.record.title, service: service, pretranscribedTurns: turns)
        Analytics.track("meeting_transcribed", ["transcript_chars": result.transcript.count,
                                                "engine": service.kind.rawValue])
        var record = job.record
        record.kind = result.kind.rawValue
        let finished = MeetingConversation.finish(result.transcript, meeting: record)
        let names = MeetingPeopleContext.names(for: record)
        return MeetingTranscriptResult(transcript: MeetingPeopleContext.correct(finished, names: names).text,
                                       originalTranscript: result.originalTranscript, kind: result.kind)
    }
}
