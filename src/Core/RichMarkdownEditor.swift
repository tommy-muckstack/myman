import AppKit
import SwiftUI

// True WYSIWYG note editing, the Scrap/Dropbox-Paper way: the user sees and
// edits RICH text (no visible asterisks); markdown is only the storage
// format, converted on load and save. First line is the title — always
// rendered big. Selecting text floats a small B/I/U bar above the selection.
//
// Formatting model: bold = Outfit-SemiBold, italic = obliqueness (Outfit has
// no italic face — Scrap hit the same wall), underline = underline attribute.

enum MarkdownRich {
    static let bodySize: CGFloat = 15
    static let titleSize: CGFloat = 24
    static let headingSize: CGFloat = 19
    static let bulletPrefix = "\u{2022}  " // "•  " — rendered, serialized back to "* "

    static func bodyFont(bold: Bool) -> NSFont {
        font(bold: bold, italic: false, title: false)
    }

    /// Single font factory. Italic is a matrix skew carrying the size —
    /// Outfit ships no italic face, and TextKit 2 ignores `.obliqueness`
    /// (kept only as a serialization marker).
    static func font(bold: Bool, italic: Bool, title: Bool, heading: Bool = false) -> NSFont {
        let size = title ? titleSize : (heading ? headingSize : bodySize)
        let name: String
        if title || heading {
            name = bold && title ? "Outfit-Bold" : "Outfit-SemiBold"
        } else {
            name = bold ? "Outfit-SemiBold" : "Outfit-Regular"
        }
        var result = NSFont(name: name, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold || title || heading ? .semibold : .regular)
        if italic {
            let skew = AffineTransform(m11: size, m12: 0, m21: 0.21 * size, m22: size, tX: 0, tY: 0)
            result = NSFont(descriptor: result.fontDescriptor.withMatrix(skew), size: 0) ?? result
        }
        return result
    }

    static var titleFont: NSFont { font(bold: false, italic: false, title: true) }

    /// Markdown stripped to plain display text — for list rows and search
    /// results, which must never show raw markers.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        for (pattern, template) in [
            ("(?m)^#{1,3} ", ""),
            ("(?m)^[-*] ", ""),
            ("<u>(.*?)</u>", "$1"),
            ("\\*\\*\\*(.*?)\\*\\*\\*", "$1"),
            ("\\*\\*(.*?)\\*\\*", "$1"),
            ("\\*([^*\\n]+?)\\*", "$1"),
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = text as NSString
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
            }
        }
        return text
    }

    // MARK: Markdown → attributed

    static func attributed(from markdown: String, firstLineIsTitle: Bool = true) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if firstLineIsTitle && index == 0 {
                result.append(parseInline(line, title: true))
            } else if line.hasPrefix("## ") || line.hasPrefix("# ") || line.hasPrefix("### ") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                result.append(NSAttributedString(string: line, attributes: [
                    .font: font(bold: false, italic: false, title: false, heading: true),
                    .foregroundColor: NSColor.textColor,
                ]))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                result.append(NSAttributedString(string: bulletPrefix, attributes: [
                    .font: bodyFont(bold: false),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                result.append(parseInline(String(line.dropFirst(2)), title: false))
            } else {
                result.append(parseInline(line, title: false))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: bodyFont(bold: false), .foregroundColor: NSColor.textColor]))
            }
        }
        return result
    }

    private static func parseInline(_ line: String, title: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Longest markers first so ** isn't eaten by *.
        let pattern = "(<u>.*?</u>|\\*\\*\\*.*?\\*\\*\\*|\\*\\*.*?\\*\\*|\\*[^*\\n]+?\\*)"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = line as NSString
        var cursor = 0

        func append(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
            guard !text.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(bold: bold, italic: italic, title: title),
                .foregroundColor: NSColor.textColor,
            ]
            if italic { attributes[.obliqueness] = 0.18 }
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        for match in regex?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] {
            append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            var token = ns.substring(with: match.range)
            if token.hasPrefix("<u>") {
                token = String(token.dropFirst(3).dropLast(4))
                let bold = token.hasPrefix("**")
                if bold { token = String(token.dropFirst(2).dropLast(2)) }
                append(token, bold: bold, underline: true)
            } else if token.hasPrefix("***") {
                append(String(token.dropFirst(3).dropLast(3)), bold: true, italic: true)
            } else if token.hasPrefix("**") {
                append(String(token.dropFirst(2).dropLast(2)), bold: true)
            } else {
                append(String(token.dropFirst(1).dropLast(1)), italic: true)
            }
            cursor = match.range.location + match.range.length
        }
        append(ns.substring(from: cursor))
        return result
    }

    // MARK: Attributed → markdown (line-based: headings and bullets restore
    // their markers; inline runs restore theirs)

    static func markdown(from attributed: NSAttributedString, firstLineIsTitle: Bool = true) -> String {
        let full = attributed.string as NSString
        var lines: [String] = []
        var location = 0
        var lineIndex = 0
        while location <= full.length {
            let remainder = NSRange(location: location, length: full.length - location)
            let newline = full.range(of: "\n", range: remainder)
            let lineEnd = newline.location == NSNotFound ? full.length : newline.location
            let lineRange = NSRange(location: location, length: lineEnd - location)
            lines.append(serializeLine(
                attributed.attributedSubstring(from: lineRange),
                title: firstLineIsTitle && lineIndex == 0))
            if newline.location == NSNotFound { break }
            location = lineEnd + 1
            lineIndex += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func serializeLine(_ line: NSAttributedString, title: Bool) -> String {
        guard line.length > 0 else { return "" }
        let firstFont = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let size = firstFont?.pointSize ?? bodySize

        var content = line
        var prefix = ""
        if !title, abs(size - headingSize) < 0.6 {
            return "## " + line.string
        }
        if line.string.hasPrefix("\u{2022}") {
            prefix = "* "
            var start = 1
            let chars = Array(line.string)
            while start < chars.count, chars[start] == " " { start += 1 }
            content = line.attributedSubstring(
                from: NSRange(location: start, length: line.length - start))
        }

        var output = prefix
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
            let text = (content.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            if title {
                output += text
                return
            }
            let font = attributes[.font] as? NSFont
            let bold = font?.fontName.localizedCaseInsensitiveContains("SemiBold") ?? false
            let italic = (attributes[.obliqueness] as? CGFloat ?? 0) > 0.01
            let underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            var wrapped = text
            if bold && italic { wrapped = "***\(wrapped)***" }
            else if bold { wrapped = "**\(wrapped)**" }
            else if italic { wrapped = "*\(wrapped)*" }
            if underline { wrapped = "<u>\(wrapped)</u>" }
            output += wrapped
        }
        return output
    }
}

// MARK: - SwiftUI wrapper

struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var markdown: String
    var firstLineIsTitle: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RichNoteTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.firstLineIsTitle = firstLineIsTitle
        textView.textStorage?.setAttributedString(
            MarkdownRich.attributed(from: markdown, firstLineIsTitle: firstLineIsTitle))
        textView.installFormatBar()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? RichNoteTextView else { return }
        // Only reload when the change came from outside the editor.
        if !context.coordinator.editing,
           MarkdownRich.markdown(from: textView.attributedString(),
                                 firstLineIsTitle: firstLineIsTitle) != markdown {
            textView.textStorage?.setAttributedString(
                MarkdownRich.attributed(from: markdown, firstLineIsTitle: firstLineIsTitle))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMarkdownEditor
        var editing = false
        init(_ parent: RichMarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RichNoteTextView else { return }
            textView.enforceTitleStyling()
            editing = true
            parent.markdown = MarkdownRich.markdown(
                from: textView.attributedString(),
                firstLineIsTitle: textView.firstLineIsTitle)
            editing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RichNoteTextView)?.updateFormatBar()
        }
    }
}

// MARK: - The text view

final class RichNoteTextView: NSTextView {
    var firstLineIsTitle = true
    private var formatBar: NSHostingView<FormatBar>?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), isEditable {
            switch event.charactersIgnoringModifiers {
            case "b": toggleBoldSelection(); return true
            case "i": toggleItalicSelection(); return true
            case "u": toggleUnderlineSelection(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// First line is the title: always big, never markered.
    func enforceTitleStyling() {
        guard firstLineIsTitle else { return }
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let firstLineEnd = text.range(of: "\n").location
        let titleLength = firstLineEnd == NSNotFound ? text.length : firstLineEnd
        if titleLength > 0 {
            let titleRange = NSRange(location: 0, length: titleLength)
            storage.enumerateAttributes(in: titleRange) { attributes, range, _ in
                let name = (attributes[.font] as? NSFont)?.fontName ?? ""
                let bold = name.localizedCaseInsensitiveContains("Outfit-Bold")
                let italic = (attributes[.obliqueness] as? CGFloat ?? 0) > 0.01
                storage.addAttribute(.font,
                    value: MarkdownRich.font(bold: bold, italic: italic, title: true), range: range)
            }
        }
        // Body runs that lost their font (typed at a boundary) get the base.
        if titleLength < text.length {
            let bodyRange = NSRange(location: titleLength, length: text.length - titleLength)
            storage.enumerateAttributes(in: bodyRange) { attributes, range, _ in
                let font = attributes[.font] as? NSFont
                if font == nil || font!.pointSize >= MarkdownRich.titleSize - 1 {
                    let bold = font?.fontName.localizedCaseInsensitiveContains("SemiBold") ?? false
                    let italic = (attributes[.obliqueness] as? CGFloat ?? 0) > 0.01
                    storage.addAttribute(.font,
                        value: MarkdownRich.font(bold: bold, italic: italic, title: false), range: range)
                }
            }
        }
        needsDisplay = true
    }

    // MARK: Formatting actions (selection only)

    private func inTitle(_ range: NSRange) -> Bool {
        guard firstLineIsTitle else { return false }
        let firstLineEnd = (string as NSString).range(of: "\n").location
        return firstLineEnd == NSNotFound || range.location < firstLineEnd
    }

    private func currentTraits(_ storage: NSTextStorage, _ range: NSRange) -> (bold: Bool, italic: Bool) {
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let name = font?.fontName ?? ""
        let bold = name.localizedCaseInsensitiveContains("SemiBold")
            || name.localizedCaseInsensitiveContains("Bold")
        let italic = (storage.attribute(.obliqueness, at: range.location,
                                        effectiveRange: nil) as? CGFloat ?? 0) > 0.01
        return (bold, italic)
    }

    func toggleBoldSelection() {
        applyToSelection { storage, range in
            let title = inTitle(range)
            let traits = currentTraits(storage, range)
            storage.addAttribute(.font,
                value: MarkdownRich.font(bold: !traits.bold, italic: traits.italic, title: title),
                range: range)
        }
    }

    func toggleItalicSelection() {
        applyToSelection { storage, range in
            let title = inTitle(range)
            let traits = currentTraits(storage, range)
            if traits.italic {
                storage.removeAttribute(.obliqueness, range: range)
            } else {
                storage.addAttribute(.obliqueness, value: 0.18, range: range)
            }
            storage.addAttribute(.font,
                value: MarkdownRich.font(bold: title ? traits.bold : traits.bold,
                                         italic: !traits.italic, title: title),
                range: range)
        }
    }

    func toggleUnderlineSelection() {
        applyToSelection { storage, range in
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            if current != 0 {
                storage.removeAttribute(.underlineStyle, range: range)
            } else {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    private func applyToSelection(_ mutate: (NSTextStorage, NSRange) -> Void) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage,
              shouldChangeText(in: range, replacementString: nil) else { return }
        mutate(storage, range)
        didChangeText()
        updateFormatBar()
    }

    // MARK: Floating format bar

    func installFormatBar() {
        let bar = NSHostingView(rootView: FormatBar(
            onBold: { [weak self] in self?.toggleBoldSelection() },
            onItalic: { [weak self] in self?.toggleItalicSelection() },
            onUnderline: { [weak self] in self?.toggleUnderlineSelection() }
        ))
        bar.isHidden = true
        addSubview(bar)
        formatBar = bar
    }

    func updateFormatBar() {
        guard let bar = formatBar else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            bar.isHidden = true
            return
        }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        guard let window, screenRect.width >= 0 else {
            bar.isHidden = true
            return
        }
        let windowRect = window.convertFromScreen(screenRect)
        let local = convert(windowRect, from: nil)
        let size = bar.fittingSize
        var origin = NSPoint(
            x: max(4, local.midX - size.width / 2),
            y: local.minY - size.height - 6 // flipped view: minY is the top
        )
        if origin.y < 0 { origin.y = local.maxY + 6 }
        bar.frame = NSRect(origin: origin, size: size)
        bar.isHidden = false
    }
}

private struct FormatBar: View {
    var onBold: () -> Void
    var onItalic: () -> Void
    var onUnderline: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            barButton(.bold, action: onBold, help: "Bold (⌘B)")
            barButton(.italic, action: onItalic, help: "Italic (⌘I)")
            barButton(.underline, action: onUnderline, help: "Underline (⌘U)")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MM.Colors.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
    }

    private func barButton(_ icon: MMIcon, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            IconView(icon: icon, size: 14, color: MM.Colors.textPrimary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.iBeam.set() }
        .help(help)
    }
}
