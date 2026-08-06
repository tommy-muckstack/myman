import AppKit

/// Deliver dictated text into the target app, or the currently focused app
/// when no target is supplied. With Accessibility granted the text is TYPED
/// via synthetic keystrokes (private event source, so held hotkey modifiers
/// don't bleed in) — the user's clipboard is never touched.
/// Without the grant, clipboard + manual ⌘V is the fallback.
func pasteText(_ text: String, into app: NSRunningApplication? = nil) {
    guard AXIsProcessTrusted() else {
        // Fallback only: clipboard so the user can ⌘V themselves.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return
    }

    let front = NSWorkspace.shared.frontmostApplication
    let target: NSRunningApplication? = {
        if let app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            return app
        }
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        return nil
    }()

    if let target, front?.processIdentifier != target.processIdentifier {
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            NSApp.hide(nil)
        }
        target.activate()
        // Spin briefly until the target actually owns the foreground —
        // typing early sends keystrokes to the wrong app.
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
    } else if target == nil {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return
    }

    typeUnicode(text)
}

/// Type text as synthetic keyboard events, ~20 UTF-16 units per event.
/// The .privateState source keeps physically-held hotkey modifiers (⌥⇧)
/// from contaminating the synthetic keystrokes.
private func typeUnicode(_ text: String) {
    let source = CGEventSource(stateID: .privateState)
    var chunk: [UniChar] = []
    func post(_ chunk: inout [UniChar]) {
        guard !chunk.isEmpty else { return }
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        usleep(8_000)
        chunk.removeAll(keepingCapacity: true)
    }
    // Iterate Characters rather than arbitrary UTF-16 slices: an emoji may
    // use two code units, and splitting that surrogate pair corrupts it.
    for character in text {
        let units = Array(String(character).utf16)
        if !chunk.isEmpty, chunk.count + units.count > 20 {
            post(&chunk)
        }
        chunk.append(contentsOf: units)
    }
    post(&chunk)
}
