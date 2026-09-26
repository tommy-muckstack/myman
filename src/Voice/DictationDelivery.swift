import AppKit
import Combine
import Carbon

@MainActor enum DictationDelivery {
    struct Outcome: Codable, Equatable {
        var state: String
        var reason: String
        var milliseconds: Int
        // Optional so recovery entries written by older versions still decode.
        var clipboardAvailable: Bool? = nil

        var isVerified: Bool { state == "verified" }
        var needsAttention: Bool { state != "verified" && state != "sent" }
        var statusLabel: String {
            if isVerified { return "Pasted" }
            if state == "sent" { return "Paste sent" }
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
        var paste: () -> PasteResult
    }

    enum PasteResult { case sent, failed, uncertain }

    /// A native menu action avoids shortcut interception in custom editors.
    /// A timeout may have executed the action, so never follow it with ⌘V.
    static func sendPasteCommand(menuAction: (() -> AXError)?, shortcut: () -> Bool) -> PasteResult {
        if let menuAction {
            switch menuAction() {
            case .success: return .sent
            case .actionUnsupported, .notImplemented: break
            case .cannotComplete, .failure: return .uncertain
            default: return .failed
            }
        }
        return shortcut() ? .sent : .failed
    }

    static func prefersPaste(bundleID: String?, bundleURL: URL?) -> Bool {
        if ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"].contains(bundleID ?? "") { return true }
        return isElectron(bundleID: bundleID, bundleURL: bundleURL)
    }

    private static func isElectron(bundleID: String?, bundleURL: URL?) -> Bool {
        if ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.vscodium", "com.exafunction.windsurf"].contains(bundleID ?? "") { return true }
        return bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
    }

    enum InsertionSupport: Equatable { case textField, pasteCommand, unavailable }

    /// Custom editors can expose only their containing window (for example
    /// Zed/GPUI). Lack of AX text readback is not lack of Paste support.
    static func insertionSupport(role: String?, subrole: String?, secureInput: Bool,
                                 hasWindow: Bool, pasteEnabled: Bool) -> InsertionSupport {
        guard !secureInput, subrole != kAXSecureTextFieldSubrole else { return .unavailable }
        if let role, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return .textField }
        let opaque = role.map { [kAXWindowRole, kAXGroupRole, kAXUnknownRole, "AXWebArea", "AXLayoutArea"].contains($0) } ?? true
        return opaque && hasWindow && pasteEnabled ? .pasteCommand : .unavailable
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
            // A sent paste already copied successfully; do not replace the
            // clipboard again while the destination may still be reading it.
            let copied: Bool? = state == "verified" ? nil : (state == "sent" ? true : copy(text))
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
            guard !Task.isCancelled, target.isFocused() else {
                return finish("clipboard", "Could not paste into the focused field. Your text is copied; paste it into the intended field.")
            }
            switch target.paste() {
            case .sent: break
            case .failed:
                return finish("clipboard", "Could not paste into the focused field. Your text is copied; paste it into the intended field.")
            case .uncertain:
                return finish("uncertain", "Paste could not be confirmed. Check the field before pasting to avoid duplicates.")
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
            if target.prefersPaste, expected == nil {
                return finish("sent", "Paste sent. This app doesn’t expose its text for confirmation.")
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
    private static func element(_ app: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(app, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func focus(_ app: AXUIElement) -> AXUIElement? { element(app, kAXFocusedUIElementAttribute) }

    /// Match the standard Command-V shortcut rather than a localized title.
    /// Bound both IPC time and traversal: a wedged app must not hang dictation.
    private static func enabledPasteCommand(_ app: AXUIElement) -> AXUIElement? {
        guard let menu = element(app, kAXMenuBarAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(0.2)
        var remaining = 120
        func visit(_ item: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= 4, remaining > 0, Date() < deadline else { return nil }
            remaining -= 1
            AXUIElementSetMessagingTimeout(item, 0.04)
            if (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "v",
               (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,
               (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == true { return item }
            for child in attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let command = visit(child, depth: depth + 1) { return command }
            }
            return nil
        }
        return visit(menu, depth: 0)
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
        var usePaste = prefersPaste(bundleID: target.bundleIdentifier, bundleURL: target.bundleURL)
        if isElectron(bundleID: target.bundleIdentifier, bundleURL: target.bundleURL) {
            // Electron's documented assistive-technology hook exposes editable
            // controls that otherwise appear as an opaque web area.
            // https://www.electronjs.org/docs/latest/tutorial/accessibility
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return clipboard("Focus changed before insertion. Paste the saved text into the intended field.")
        }
        let field = focus(app)
        let window = element(app, kAXFocusedWindowAttribute)
        if let field { AXUIElementSetMessagingTimeout(field, 0.25) }
        let role = field.flatMap { attribute($0, kAXRoleAttribute) as? String }
        let subrole = field.flatMap { attribute($0, kAXSubroleAttribute) as? String }
        let secure = IsSecureEventInputEnabled()
        var pasteCommand: AXUIElement?
        var support = insertionSupport(role: role, subrole: subrole, secureInput: secure,
                                       hasWindow: window != nil, pasteEnabled: false)
        if support == .unavailable, !secure, subrole != kAXSecureTextFieldSubrole {
            // Paste availability may depend on the clipboard containing text.
            guard copyToClipboard(text) else { return clipboard("Could not copy the dictation. Use Copy to try again.") }
            pasteCommand = enabledPasteCommand(app)
            support = insertionSupport(role: role, subrole: subrole, secureInput: secure,
                                       hasWindow: window != nil, pasteEnabled: pasteCommand != nil)
        }
        guard support != .unavailable else { return clipboard("Choose an editable field, then paste the saved text.") }
        if support == .pasteCommand { usePaste = true }
        if usePaste, pasteCommand == nil, !isElectron(bundleID: target.bundleIdentifier, bundleURL: target.bundleURL) {
            pasteCommand = enabledPasteCommand(app)
        }
        let before = support == .textField ? field.flatMap { attribute($0, kAXValueAttribute) as? String } : nil
        var selected = CFRange(location: kCFNotFound, length: 0)
        if support == .textField, let field, let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &selected)
        }
        func stillFocused() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  !IsSecureEventInputEnabled() else { return false }
            if let window {
                guard element(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true else { return false }
            }
            if let field { return focus(app).map { CFEqual($0, field) } == true }
            return focus(app) == nil && window != nil
        }
        var settable = DarwinBoolean(false)
        var valueSettable = DarwinBoolean(false)
        var canReplace = false
        if support == .textField, let field {
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable)
            canReplace = AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue && valueSettable.boolValue
        }
        let source = CGEventSource(stateID: .privateState)
        let destination = Target(prefersPaste: usePaste, before: before,
            selection: NSRange(location: selected.location, length: selected.length),
            isFocused: stillFocused, readValue: { field.flatMap { attribute($0, kAXValueAttribute) as? String } },
            replaceSelection: { value in
                guard canReplace, let field else { return false }
                return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, value as CFString) == .success
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
                let menuAction: (() -> AXError)? = pasteCommand.map { command in
                    {
                        AXUIElementSetMessagingTimeout(command, 0.25)
                        return AXUIElementPerformAction(command, kAXPressAction as CFString)
                    }
                }
                return sendPasteCommand(menuAction: menuAction) {
                    // ANSI V, with explicit flags so a held dictation modifier does
                    // not turn this into a different shortcut.
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
                    down.flags = .maskCommand; up.flags = .maskCommand
                    down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
                    return true
                }
            })
        DictationCorrectionWatch.shared.stop()
        var outcome = await deliver(text, to: destination, copy: copyToClipboard)
        if outcome.isVerified, AgentContext.jobID.isEmpty, let before,
           let range = destination.selection, range.location != NSNotFound,
           before.utf16.count <= 50_000, let expected = replacement(before: before, range: range, text: text),
           destination.readValue() == expected {
            let value = before as NSString
            let prefix = value.substring(to: range.location)
            let suffix = value.substring(from: range.location + range.length)
            DictationCorrectionWatch.shared.start(text: text) {
                guard destination.isFocused(), let actual = destination.readValue(), actual.count <= 50_000,
                      actual.hasPrefix(prefix), actual.hasSuffix(suffix), actual.count >= prefix.count + suffix.count else { return nil }
                return String(actual.dropFirst(prefix.count).dropLast(suffix.count))
            }
        }
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
