import AppKit
import Foundation

/// Reset, export and the audit log, for the Advanced area. Only the keys listed here are touched.
/// Credentials, tokens, account identifiers and the Brain folder's contents are never in the list,
/// so a reset cannot delete them and an export cannot include them.
enum SettingsTools {
    /// Keys that reset returns to their defaults. Each one is a setting the person chose in this app.
    static let resettable: [String] = [
        AgentAccessPreset.key, AgentRules.key, PauseEverything.pausedKey, PauseEverything.snapshotKey,
        CaptureQuality.key, "captureSound", "captureWindowMetadata", "captureMetadataExcludedApps",
        "agentActionsEnabled", AgentFolderBridge.enabledKey,
    ] + AgentConsent.keys.values.sorted()

    /// Keys an export carries. Same rule: nothing secret, nothing that identifies an account.
    static let exportable: [String] = resettable.filter { $0 != PauseEverything.snapshotKey }

    /// The settings as a plain dictionary, with only the exportable keys that are set.
    static func exportDictionary(_ defaults: UserDefaults = .standard) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in exportable { if let value = defaults.object(forKey: key) { out[key] = value } }
        return out
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in resettable { defaults.removeObject(forKey: key) }
    }

    /// Asks where to save, then writes the export as JSON.
    @MainActor static func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "my-man-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: exportDictionary(), options: [.sortedKeys, .prettyPrinted])
            try data.write(to: url, options: .atomic)
        } catch {
            Toast.show("Couldn’t save the settings file", systemImage: "exclamationmark.triangle")
        }
    }

    /// Opens the audit log in Finder, creating an empty one first so there is something to show.
    @MainActor static func showAuditLog() {
        let folder = Brain.root.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("audit.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    @MainActor static func confirmReset() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset these settings to their defaults?"
        alert.informativeText = "Agent access and Always allowed rules, Pause everything, Image quality, Screenshot sound, window details, and the agent switches. Your Brain folder, credentials and library are not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
