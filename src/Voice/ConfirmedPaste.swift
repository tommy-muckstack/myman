import AppKit

/// A paste the destination has to come and get. The text is promised to the
/// pasteboard rather than written to it, so the moment an app reads it is
/// observable: that read is the confirmation that ⌘V landed, in any app,
/// including editors that expose no text to Accessibility (Zed/GPUI,
/// terminals, canvases). The item is marked transient and concealed so
/// clipboard managers skip it instead of triggering the promise themselves.
@MainActor final class ConfirmedPaste: NSObject, NSPasteboardItemDataProvider {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let text: String
    private let pasteboard: NSPasteboard
    private(set) var requested = false
    /// nil when the earlier clipboard could not be kept (too large, or
    /// unreadable); the dictation then stays on the clipboard.
    private var saved: [NSPasteboardItem]?
    private var changeCount = 0

    /// `restoring` is what the person had copied before this dictation
    /// touched the clipboard; it goes back once the paste is confirmed.
    init(_ text: String, restoring saved: [NSPasteboardItem]?, pasteboard: NSPasteboard = .general) {
        self.text = text
        self.saved = saved
        self.pasteboard = pasteboard
    }

    /// A detached copy of the clipboard's current items, or nil when it is
    /// too large to hold on to (an image or file set the person copied).
    static func snapshot(_ pasteboard: NSPasteboard = .general, limit: Int = 8 * 1024 * 1024) -> [NSPasteboardItem]? {
        var total = 0
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            var restorable = false
            for type in item.types where type != transient && type != concealed {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= limit else { return nil }
                copy.setData(data, forType: type); restorable = true
            }
            if restorable { copies.append(copy) }
        }
        return copies
    }

    /// Promise the text instead of writing it.
    @discardableResult func write() -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setDataProvider(self, forTypes: [.string]) else { return false }
        item.setData(Data(), forType: Self.transient)
        item.setData(Data(), forType: Self.concealed)
        guard pasteboard.writeObjects([item]) else { return false }
        changeCount = pasteboard.changeCount
        return true
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        MainActor.assumeIsolated {
            requested = true
            item.setString(text, forType: type)
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    /// Wait for the destination to read the promised text.
    func waitForRead(milliseconds: Int = 700) async -> Bool {
        var waited = 0
        while !requested, waited < milliseconds {
            try? await Task.sleep(for: .milliseconds(15))
            waited += 15
        }
        return requested
    }

    /// Unconfirmed: leave the dictation itself on the clipboard (a plain,
    /// durable copy) so the person can paste it by hand.
    func keepTextOnClipboard() -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Confirmed: put back what the person had copied, unless something else
    /// has used the clipboard since. Late readers already have the text.
    func restoreAfterPaste(delay: Duration = .milliseconds(800)) {
        guard let saved else { return }
        let pasteboard = pasteboard, changeCount = changeCount
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Held hotkey modifiers turn ⌘V into a different shortcut (⌥⌘V, ⇧⌘V).
    /// Wait briefly for the person's fingers to leave the keys.
    static func waitForModifierRelease(milliseconds: Int = 400) async {
        var waited = 0
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, waited < milliseconds {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }
}
