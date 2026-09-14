import AppKit
import Combine

@MainActor enum DictationDelivery {
    struct Outcome: Codable, Equatable {
        var state: String
        var reason: String
        var milliseconds: Int
    }
    static func replacement(before: String, range: NSRange, text: String) -> String? {
        let value = before as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.location <= value.length, range.length <= value.length - range.location else { return nil }
        return value.replacingCharacters(in: range, with: text)
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func focus(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    /// Called after the transcript is saved. Never retries uncertain delivery:
    /// doing so could insert the same sentence twice.
    static func deliver(_ text: String) async -> Outcome {
        let start = Date()
        func result(_ state: String, _ reason: String) -> Outcome {
            Outcome(state: state, reason: reason, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        }
        func clipboard(_ reason: String) -> Outcome {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return result("clipboard", reason)
        }
        guard AXIsProcessTrusted() else { return clipboard("Allow Accessibility to insert text automatically, or paste the saved text yourself.") }
        guard let target = NSWorkspace.shared.frontmostApplication, target.bundleIdentifier != Bundle.main.bundleIdentifier else { return clipboard("Choose a text field, then paste. Your dictation is saved.") }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard let field = focus(app), let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return clipboard("This field does not support verified insertion. Paste the saved text yourself.") }
        let before = attribute(field, kAXValueAttribute) as? String
        var selected = CFRange(location: kCFNotFound, length: 0)
        if let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &selected)
        }
        let expected = before.flatMap { replacement(before: $0, range: NSRange(location: selected.location, length: selected.length), text: text) }
        func stillFocused() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier && focus(app).map { CFEqual($0, field) } == true
        }
        guard stillFocused() else { return clipboard("Focus changed before insertion. Paste the saved text into the intended field.") }
        var settable = DarwinBoolean(false)
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable)
        let canReplace = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue && valueSettable.boolValue
        if !canReplace || AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) != .success {
            let source = CGEventSource(stateID: .privateState)
            var sent = false
            for chunk in chunks(text) {
                guard stillFocused() else { return result("uncertain", "Focus changed during insertion. Review the field before copying the saved dictation; some text may already be present.") }
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return sent ? result("uncertain", "Insertion was interrupted. Review the field before retrying.") : clipboard("Could not insert text. Paste the saved dictation yourself.")
                }
                var units = Array(chunk.utf16)
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap); sent = true
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard stillFocused(), let expected, attribute(field, kAXValueAttribute) as? String == expected else {
            return result("unverified", "Text was sent, but this app did not confirm the result. Your dictation is saved; inspect the field before retrying.")
        }
        return result("verified", "Text inserted and verified in the focused field.")
    }
    static func chunks(_ text: String) -> [String] {
        var result: [String] = [], chunk = ""
        for character in text {
            if !chunk.isEmpty && chunk.utf16.count + String(character).utf16.count > 20 { result.append(chunk); chunk = "" }
            chunk.append(character)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

@MainActor final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    struct Entry: Codable, Identifiable {
        var id: String
        var text: String
        var targetBundle: String
        var createdAt: Date
        var outcome: DictationDelivery.Outcome
        var correctedText: String?
    }
    @Published private(set) var entries: [Entry] = []
    private var loadFailed = false
    private let file: URL
    private let learn: (String) -> Void
    init(root: URL? = nil, learn: @escaping (String) -> Void = DictationCleanup.learn) {
        self.learn = learn
        let root = root ?? VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        file = root.appendingPathComponent("DictationDelivery/history.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
            } catch { loadFailed = true }
        }
    }
    func save(_ entry: Entry) throws {
        var next = entries.filter { $0.id != entry.id }; next.insert(entry, at: 0)
        try persist(Array(next.prefix(200)))
    }
    func correct(_ id: String, text: String, human: Bool = true) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 50000, let i = entries.firstIndex(where: { $0.id == id }) else { throw AgentError("INVALID_ARGUMENTS", "Choose a saved dictation and enter a correction.") }
        var next = entries; next[i].correctedText = text
        try persist(next)
        if human { learn(text) }
    }
    func purge(itemID: String?) {
        let next = entries.filter { itemID != nil && "dictation-" + $0.id != itemID }
        do { try persist(next) } catch { entries = []; try? FileManager.default.removeItem(at: file) }
    }
    private func persist(_ next: [Entry]) throws {
        guard !loadFailed else { throw AgentError("RECOVERY_UNAVAILABLE", "Existing recovery history could not be read. It has been preserved for recovery.") }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 8 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Dictation recovery history is full.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
    }
}

enum DictationAppStyles {
    static func tone(for bundle: String?, fallback: DictationTone, defaults: UserDefaults = .standard) -> DictationTone {
        guard let bundle, let value = defaults.dictionary(forKey: "dictationAppStyles")?[bundle] as? String else { return fallback }
        return DictationTone(rawValue: value) ?? fallback
    }
    static func set(_ tone: DictationTone?, for bundle: String, defaults: UserDefaults = .standard) {
        var styles = defaults.dictionary(forKey: "dictationAppStyles") ?? [:]
        styles[bundle] = tone?.rawValue; defaults.set(styles, forKey: "dictationAppStyles")
    }
}
