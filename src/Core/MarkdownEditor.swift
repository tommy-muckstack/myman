import AppKit
import SwiftUI

// Dropbox-Paper-spirit markdown editor: one clean column of text, no chrome.
// It's a styled-source editor (Bear-style): you type markdown, and headers /
// bold / italic / bullets render styled in place. ⌘B and ⌘I wrap the selection.

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.restyle()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkdownTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.restyle()
        }
        textView.isEditable = editable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            parent.text = textView.string
            textView.restyle()
        }
    }
}

final class MarkdownTextView: NSTextView {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), isEditable {
            switch event.charactersIgnoringModifiers {
            case "b": wrapSelection(with: "**"); return true
            case "i": wrapSelection(with: "*"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func wrapSelection(with marker: String) {
        let range = selectedRange()
        let source = string as NSString
        let selected = range.length > 0 ? source.substring(with: range) : ""
        let replacement = "\(marker)\(selected)\(marker)"
        if shouldChangeText(in: range, replacementString: replacement) {
            replaceCharacters(in: range, with: replacement)
            didChangeText()
            // Place the caret inside empty markers, or after the wrap.
            let position = range.length > 0
                ? range.location + replacement.count
                : range.location + marker.count
            setSelectedRange(NSRange(location: position, length: 0))
        }
    }

    /// Style the raw markdown in place. Whole-document restyle — fine at
    /// meeting-notes scale.
    func restyle() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        let source = string as NSString

        func font(_ size: CGFloat, _ weight: String) -> NSFont {
            NSFont(name: "Outfit-\(weight)", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight == "Regular" ? .regular : .semibold)
        }

        storage.beginEditing()
        storage.setAttributes([
            .font: font(15, "Regular"),
            .foregroundColor: NSColor.textColor,
        ], range: all)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        storage.addAttribute(.paragraphStyle, value: paragraph, range: all)

        func style(pattern: String, options: NSRegularExpression.Options = [.anchorsMatchLines],
                   _ apply: (NSRange) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: string, range: all) { match, _, _ in
                if let match { apply(match.range) }
            }
        }

        // Headers
        style(pattern: "^# .*$") { storage.addAttribute(.font, value: font(24, "SemiBold"), range: $0) }
        style(pattern: "^## .*$") { storage.addAttribute(.font, value: font(19, "SemiBold"), range: $0) }
        style(pattern: "^### .*$") { storage.addAttribute(.font, value: font(16, "SemiBold"), range: $0) }
        // Bold then italic (bold first so ** wins over *)
        style(pattern: "\\*\\*[^*\\n]+\\*\\*", options: []) {
            storage.addAttribute(.font, value: font(15, "SemiBold"), range: $0)
        }
        style(pattern: "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)", options: []) { range in
            let italic = NSFontManager.shared.convert(font(15, "Regular"), toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: range)
        }
        // Bullets and markers rendered quieter
        style(pattern: "^[-*] ") { range in
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        // Dim the markdown syntax characters themselves
        style(pattern: "\\*\\*|(?<!\\*)\\*(?!\\*)|^#{1,3} ", options: [.anchorsMatchLines]) { range in
            if source.length >= range.location + range.length {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            }
        }
        storage.endEditing()
    }
}
