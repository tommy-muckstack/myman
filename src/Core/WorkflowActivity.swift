import Foundation

@MainActor enum WorkflowActivity {
    static var cancel: (String, Bool) throws -> Void = { _, _ in throw AgentError("NOT_RUNNING", "No active command can be stopped.") }
    static let cancellable: Set<String> = ["screenshot.ocr", "screenshot.compare", "recording.frames", "recording.export", "font.match", "font.preview"]
    static func references(_ args: [String: Any]) -> [String: Any] {
        args.filter { ["id", "source_id", "target_id", "item_id", "session_id", "before_id", "after_id", "ids", "source_ids", "related_ids", "expected_revision"].contains($0.key) }
    }
    static func continuation(_ job: [String: Any]) -> String {
        "Inspect My Man request \(job["id"] as? String ?? "") and its saved result before continuing. Last state: \(job["state"] as? String ?? "unknown"). Do not replay the request automatically. Confirm the source revisions and reuse any existing saved output."
    }
}
