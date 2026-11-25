import Foundation

/// The seven settings areas. Each idea lives in exactly one of them.
enum SettingsArea: String, CaseIterable, Identifiable {
    case general, capture, agents, brainFolder, sharingLibrary, privacy, advanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .capture: return "Capture"
        case .agents: return "Agents"
        case .brainFolder: return "Brain folder"
        case .sharingLibrary: return "Sharing & library"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }
}

/// One findable setting. The search reads `title` and `keywords`, so people can
/// type plain words ("record", "camera", "folder") and land on the right area.
struct SettingsEntry: Equatable {
    let title: String
    let keywords: [String]
    let areas: [SettingsArea]
}

enum SettingsSearch {
    static let entries: [SettingsEntry] = [
        SettingsEntry(title: "Launch at login", keywords: ["startup", "start", "login", "boot"], areas: [.general]),
        SettingsEntry(title: "Global hotkeys", keywords: ["shortcut", "keys", "keyboard", "hotkey"], areas: [.general]),
        SettingsEntry(title: "Appearance and text size", keywords: ["theme", "dark", "light", "text", "size", "color"], areas: [.general]),
        SettingsEntry(title: "Screenshots", keywords: ["screenshot", "capture", "picture", "image", "photo"], areas: [.capture]),
        SettingsEntry(title: "Screenshot folder", keywords: ["folder", "save", "location", "where", "path"], areas: [.capture]),
        SettingsEntry(title: "Screenshot sound", keywords: ["sound", "shutter", "audio"], areas: [.capture]),
        SettingsEntry(title: "Recording", keywords: ["record", "video", "clip", "screen recording", "movie"], areas: [.capture, .privacy]),
        SettingsEntry(title: "Text recognition (OCR)", keywords: ["ocr", "text", "read", "search text"], areas: [.capture]),
        SettingsEntry(title: "Themes and search on this Mac", keywords: ["theme", "search", "group", "similar"], areas: [.capture]),
        SettingsEntry(title: "Camera for narration", keywords: ["camera", "webcam", "face", "narration", "bubble", "front"], areas: [.capture, .privacy]),
        SettingsEntry(title: "Microphone", keywords: ["mic", "microphone", "audio", "voice", "dictation", "sound"], areas: [.privacy, .capture]),
        SettingsEntry(title: "Let Claude and other agents use MyMan", keywords: ["agent", "claude", "ai", "assistant", "allow", "access", "preset"], areas: [.agents]),
        SettingsEntry(title: "Always allowed", keywords: ["always", "remember", "revoke", "approval"], areas: [.agents]),
        SettingsEntry(title: "Your Brain folder", keywords: ["folder", "brain", "agent", "cloud", "requests", "connected"], areas: [.brainFolder]),
        SettingsEntry(title: "Library", keywords: ["library", "notes", "tasks", "local", "items"], areas: [.sharingLibrary]),
        SettingsEntry(title: "Sharing", keywords: ["share", "publish", "link", "public", "upload"], areas: [.sharingLibrary]),
        SettingsEntry(title: "Permissions", keywords: ["permission", "privacy", "fix", "access", "screen recording", "accessibility", "camera", "mic"], areas: [.privacy]),
        SettingsEntry(title: "Pause everything", keywords: ["pause", "stop", "off", "disable", "everything"], areas: [.privacy, .general]),
        SettingsEntry(title: "Meetings", keywords: ["meeting", "auto record", "calendar", "notes"], areas: [.general]),
        SettingsEntry(title: "Dictation", keywords: ["dictate", "speech", "voice", "transcribe"], areas: [.advanced]),
        SettingsEntry(title: "AI providers", keywords: ["ai", "model", "provider", "key", "llm", "claude", "openai"], areas: [.advanced]),
        SettingsEntry(title: "Calendar and people for agents", keywords: ["calendar", "people", "contacts", "schedule", "booking"], areas: [.advanced]),
        SettingsEntry(title: "Command line helper", keywords: ["cli", "terminal", "command", "script", "myman"], areas: [.advanced]),
    ]

    /// Every word in the query must match the start of a word in the title or a keyword, or sit inside one.
    static func results(for query: String) -> [SettingsEntry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = ([entry.title] + entry.keywords).map { $0.lowercased() }
            return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
        }
    }
}

/// Maps the old per-grant switches to the one preset the new Agents card shows.
/// Existing choices are kept: nothing is turned on or off, only the picker is set.
enum AgentAccessMigration {
    static func preset(grants: [String: Bool]) -> AgentAccessPreset {
        let on = AgentAccessPreset.presetGrants.filter { grants[$0] == true }.count
        if on == 0 { return .off }
        if on == AgentAccessPreset.presetGrants.count { return .trusted }
        return .ask
    }

    /// True when the app has ever stored an agent setting. A fresh install has none,
    /// so it sees no migration notice.
    static func isExistingInstall(_ defaults: UserDefaults) -> Bool {
        ["agentActionsEnabled", "agentCaptureEnabled", "agentRecordingEnabled", "agentLibraryEnabled", "agentFolderBridgeEnabled"]
            .contains { defaults.object(forKey: $0) != nil }
    }

    static let noticeSeenKey = "settingsSimplifiedNoticeSeen"
}

/// Pause everything: stops capture, recording, agent actions and the Brain folder at once.
/// The switches as they were are kept, and resume puts them back exactly.
enum PauseEverything {
    static let pausedKey = "settingsPaused"
    static let snapshotKey = "settingsPauseSnapshot"
    static let keys = ["agentActionsEnabled", "agentCaptureEnabled", "agentMarkupEnabled", "agentRecordingEnabled", "agentControlEnabled",
                       "agentFolderBridgeEnabled", "captureSemanticSearch"]

    static func isPaused(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: pausedKey) }

    static func pause(_ defaults: UserDefaults) {
        guard !isPaused(defaults) else { return }
        // An unset key is recorded as null, so resume can unset it again instead of leaving it false.
        var snapshot: [String: Any] = [:]
        for key in keys { snapshot[key] = defaults.object(forKey: key) == nil ? NSNull() : defaults.bool(forKey: key) }
        // Stored as plain values so a crash mid-pause cannot lose what was on.
        defaults.set(try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), forKey: snapshotKey)
        for key in keys { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: pausedKey)
    }

    static func resume(_ defaults: UserDefaults) {
        guard isPaused(defaults) else { return }
        if let data = defaults.data(forKey: snapshotKey), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in saved {
                if let flag = value as? Bool { defaults.set(flag, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: snapshotKey)
        defaults.set(false, forKey: pausedKey)
    }
}

/// The four permissions the Privacy area shows, with the System Settings pane each Fix button opens.
enum PrivacyPermission: String, CaseIterable, Identifiable {
    case screenRecording, camera, microphone, accessibility

    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenRecording: return "Screen recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }
    var why: String {
        switch self {
        case .screenRecording: return "Screenshots and recordings of what is on screen."
        case .camera: return "Narration bubble in recordings."
        case .microphone: return "Your voice for dictation, meetings and narration."
        case .accessibility: return "Reads a browser address and clicks you approve."
        }
    }
    /// Deep link to the exact pane in System Settings.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}
