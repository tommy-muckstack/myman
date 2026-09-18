import AppKit
import Combine

@MainActor enum DictationDelivery {
    struct Outcome: Codable, Equatable {
        var state: String
        var reason: String
        var milliseconds: Int
        // Optional so recovery entries written by older versions still decode.
        var clipboardAvailable: Bool? = nil

        var isVerified: Bool { state == "verified" }
        var statusLabel: String {
            if isVerified { return "Pasted" }
            if clipboardAvailable == true || (state == "clipboard" && clipboardAvailable == nil) {
                return state == "clipboard" ? "Copied — ⌘V to paste" : "Unconfirmed — text copied"
            }
            return "Saved — use Copy"
        }
    }

    /// The delivery algorithm is shared by the native adapter and deterministic
    /// regression fixtures. No fallback inserts a second time after an uncertain write.
    struct Target {
        var prefersPaste: Bool
        var before: String?
        var selection: NSRange?
        var isFocused: () -> Bool
        var readValue: () -> String?
        var replaceSelection: (String) -> Bool
        var typeChunk: (String) -> Bool
        var paste: () -> Bool
    }

    static func prefersPaste(bundleID: String?, bundleURL: URL?) -> Bool {
        if ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.vscodium", "com.exafunction.windsurf"].contains(bundleID ?? "") { return true }
        return bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
    }

    @discardableResult static func copyToClipboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    static func deliver(_ text: String, to target: Target,
                        copy: (String) -> Bool,
                        pause: (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }) async -> Outcome {
        let start = Date()
        func finish(_ state: String, _ reason: String) -> Outcome {
            let copied = state == "verified" ? nil : copy(text)
            return Outcome(state: state, reason: copied == false ? "Your dictation is saved, but the clipboard could not be updated. Use Copy to try again; check the field first." : reason,
                           milliseconds: Int(Date().timeIntervalSince(start) * 1000), clipboardAvailable: copied)
        }
        guard !Task.isCancelled, target.isFocused() else {
            return finish("clipboard", "Focus changed before insertion. Paste the saved text into the intended field.")
        }
        let expected = target.before.flatMap { before in
            target.selection.flatMap { replacement(before: before, range: $0, text: text) }
        }
        if target.prefersPaste {
            // Electron can acknowledge AXSelectedText writes without editing its
            // document. Send one normal Paste command, never an AX write first.
            guard copy(text) else { return finish("clipboard", "Could not copy the dictation. Use Copy to try again.") }
            guard !Task.isCancelled, target.isFocused(), target.paste() else {
                return finish("clipboard", "Could not paste into the focused field. Your text is copied; paste it into the intended field.")
            }
        } else if !target.replaceSelection(text) {
            var sent = false
            for chunk in chunks(text) {
                guard !Task.isCancelled, target.isFocused() else {
                    return finish(sent ? "uncertain" : "clipboard", "Insertion stopped because focus changed. Your text is copied; check the field before pasting to avoid duplicates.")
                }
                guard target.typeChunk(chunk) else {
                    return finish(sent ? "uncertain" : "clipboard", "Insertion was interrupted. Your text is copied; check the field before pasting to avoid duplicates.")
                }
                sent = true
                await pause(8)
            }
        }
        // Allow asynchronous editors time to expose their new value. Poll only;
        // an uncertain insertion is never retried automatically.
        for delay in [120, 100, 200] {
            await pause(delay)
            guard !Task.isCancelled, target.isFocused() else {
                return finish("uncertain", "Focus changed after insertion. Your text is copied; check the field before pasting to avoid duplicates.")
            }
            // Cursor's empty contenteditable paragraph exposes "\n" before
            // typing, then drops that placeholder when the first text arrives.
            let dropsEmptyParagraph = target.prefersPaste && target.before == "\n"
                && target.selection == NSRange(location: 0, length: 0)
            if let expected, let actual = target.readValue(), actual != target.before,
               actual == expected || (dropsEmptyParagraph && actual == text) {
                return finish("verified", "Text inserted and verified in the focused field.")
            }
        }
        return finish("unverified", "Insertion could not be confirmed. Your text is copied; check the field before pressing ⌘V to avoid duplicates.")
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
    /// Called after the transcript is saved. The frontmost app is never activated
    /// or changed here, and every event is guarded by the original field identity.
    static func deliver(_ text: String) async -> Outcome {
        let start = Date()
        func result(_ state: String, _ reason: String) -> Outcome {
            Outcome(state: state, reason: reason, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        }
        func clipboard(_ reason: String) -> Outcome {
            var outcome = result("clipboard", reason)
            outcome.clipboardAvailable = copyToClipboard(text)
            if outcome.clipboardAvailable == false { outcome.reason = "Your dictation is saved, but copying failed. Use Copy to try again." }
            return outcome
        }
        guard AXIsProcessTrusted() else { return clipboard("Allow Accessibility to insert text automatically, or paste the saved text yourself.") }
        guard let target = NSWorkspace.shared.frontmostApplication, target.bundleIdentifier != Bundle.main.bundleIdentifier else { return clipboard("Choose a text field, then paste. Your dictation is saved.") }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let usePaste = prefersPaste(bundleID: target.bundleIdentifier, bundleURL: target.bundleURL)
        if usePaste {
            // Electron's documented assistive-technology hook exposes editable
            // controls that otherwise appear as an opaque web area.
            // https://www.electronjs.org/docs/latest/tutorial/accessibility
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return clipboard("Focus changed before insertion. Paste the saved text into the intended field.")
        }
        guard let field = focus(app), let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return clipboard("This field does not support verified insertion. Paste the saved text yourself.") }
        AXUIElementSetMessagingTimeout(field, 0.25)
        let before = attribute(field, kAXValueAttribute) as? String
        var selected = CFRange(location: kCFNotFound, length: 0)
        if let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &selected)
        }
        func stillFocused() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier && focus(app).map { CFEqual($0, field) } == true
        }
        var settable = DarwinBoolean(false)
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable)
        let canReplace = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue && valueSettable.boolValue
        let source = CGEventSource(stateID: .privateState)
        let destination = Target(prefersPaste: usePaste, before: before,
            selection: NSRange(location: selected.location, length: selected.length),
            isFocused: stillFocused, readValue: { attribute(field, kAXValueAttribute) as? String },
            replaceSelection: { value in
                canReplace && AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, value as CFString) == .success
            }, typeChunk: { chunk in
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }
                var units = Array(chunk.utf16)
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
                return true
            }, paste: {
                // ANSI V, with explicit flags so a held dictation modifier does
                // not turn this into a different shortcut.
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
                return true
            })
        var outcome = await deliver(text, to: destination, copy: copyToClipboard)
        outcome.milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        return outcome
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
