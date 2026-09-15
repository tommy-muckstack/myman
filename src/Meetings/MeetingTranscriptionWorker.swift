import Foundation

/// Final transcripts have their own speech models. The controller serializes
/// jobs; recording, live transcription, and dictation never use this engine.
actor MeetingTranscriptionWorker {
    private let service = TranscriptionService()

    func process(_ job: MeetingController.TranscriptionJob) async -> MeetingTranscriptResult {
        let timer = MeetingProcessingTimer()
        if !service.isReady { await service.load(kind: .qwen3) }
        timer.finish("speech_model_ready")
        let result = await MeetingController.buildTranscriptResult(
            micPath: job.micPath, systemPath: job.systemPath,
            candidates: job.candidates, corrections: job.record.liveCorrections, service: service)
        Analytics.track("meeting_transcribed", ["transcript_chars": result.transcript.count,
                                                "engine": service.kind.rawValue])
        return result
    }
}
