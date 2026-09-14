import Foundation

/// App-enforced consent, shared by socket clients. Grants are only changed in
/// Settings by the human; settings.update deliberately cannot enable them.
enum AgentConsent {
    static let keys = ["capture": "agentCaptureEnabled", "markup": "agentMarkupEnabled",
                       "recording": "agentRecordingEnabled", "library": "agentLibraryEnabled", "sharing": "agentSharingEnabled"]
    static let cleanup: Set<String> = ["recording.stop", "recording.cancel", "recording.pause", "meeting.stop", "meeting.discard", "dictation.stop", "dictation.cancel", "capture.scroll.stop", "capture.scroll.cancel", "capture.scroll.status", "workflow.cancel", "share.revoke"]
    @MainActor static func requirements(_ action: String) -> [String] {
        (AgentActions.catalog["actions"] as? [[String: Any]])?.first(where: { $0["name"] as? String == action })?["permissions"] as? [String] ?? ["library"]
    }
    @MainActor static func validate(_ action: String, args: [String: Any], defaults: UserDefaults = .standard) throws {
        // A revoked grant must never prevent stopping a session; its ID is
        // still checked by the controller before stopping or discarding it.
        if cleanup.contains(action) { return }
        let diagnostic = ["app.status", "app.doctor", "settings.read", "screens.list", "recording.status"].contains(action)
        if !diagnostic {
            guard defaults.object(forKey: "agentActionsEnabled") as? Bool ?? true else { throw AgentError("AGENT_DISABLED", "Local app actions are disabled in Settings → Agents.") }
            for group in requirements(action) {
                guard defaults.bool(forKey: keys[group]!) else { throw AgentError("AGENT_DISABLED", "Enable \(group) access in My Man Settings → Agents for this action.") }
            }
        }
        if ["item.delete", "task.delete", "history.clear", "share.publish"].contains(action), args["confirm"] as? Bool != true {
            throw AgentError("CONFIRMATION_REQUIRED", "This destructive action requires --confirm (confirm=true).")
        }
    }
    static func status(_ defaults: UserDefaults = .standard) -> [String: Bool] {
        var result = keys.mapValues { defaults.bool(forKey: $0) }
        result["enabled"] = defaults.object(forKey: "agentActionsEnabled") as? Bool ?? true
        return result
    }
}
