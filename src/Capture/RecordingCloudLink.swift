import AppKit

/// Copies a cloud link for a saved screen recording. Uses the same sharing path as the Share button:
/// first use asks once, the link lasts 24 hours, and comments stay off.
@MainActor enum RecordingCloudLink {
    /// The recording may still be indexing right after it is saved, so this waits for up to 30 seconds.
    static func copy(recordingID: String) {
        guard !SharePublishing.shared.endpoint.isEmpty else {
            WorkflowCenter.shared.open(tab: "sharing")
            Toast.show("Set up sharing first, then copy the link again.", systemImage: "exclamationmark.triangle")
            return
        }
        Task { @MainActor in
            do {
                let item = try await indexedItem(recordingID: recordingID)
                Toast.show("Uploading recording…", systemImage: "icloud.and.arrow.up")
                let receipt = try await SharePublishing.shared.publish(item: item, seconds: 86400)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receipt.url, forType: .string)
                Toast.show("Cloud link copied. Expires in 24 hours.")
            } catch {
                Toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle", actionLabel: "Review",
                           action: { WorkflowCenter.shared.open(tab: "sharing") }, duration: 12)
            }
        }
    }

    /// The most recent saved recording, for the menu bar item.
    static func copyLatest() {
        guard let latest = try? CaptureIndex.history(filter: CaptureFilter(kind: "recording"), limit: 1).first else {
            Toast.show("No recordings yet.", systemImage: "video.slash")
            return
        }
        copy(recordingID: String(latest.id.dropFirst("recording-".count)))
    }

    private static func indexedItem(recordingID: String) async throws -> CaptureItem {
        for _ in 0 ..< 60 {
            if let item = CaptureIndex.item("recording-" + recordingID), !item.excluded { return item }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AgentError("NOT_READY", "This recording is still being prepared. Try Copy Cloud Link again in a moment.")
    }
}
