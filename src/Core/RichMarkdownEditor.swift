import AppKit
import SwiftUI

@MainActor final class RichEditorSession: ObservableObject {
    weak var textView: RichNoteTextView?
    func insert(_ block: DocumentBlock) { textView?.applyBlock(block) }
}

enum DocumentBlock: String, CaseIterable, Identifiable {
    case text, heading, subheading, bullet, numbered, checklist, quote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "Text"
        case .heading: return "Heading"
        case .subheading: return "Subheading"
        case .bullet: return "Bulleted list"
        case .numbered: return "Numbered list"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .heading: return "textformat.size.larger"
        case .subheading: return "textformat.size.smaller"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "text.quote"
        }
    }
    var prefix: String {
        switch self {
        case .text: return ""
        case .heading: return "## "
        case .subheading: return "### "
        case .bullet: return "- "
        case .numbered: return "1. "
        case .checklist: return "- [ ] "
        case .quote: return "> "
        }
    }
}

struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var markdown: String
    var firstLineIsTitle = true
    var session: RichEditorSession? = nil
    var placeholder = "Start writing…"

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RichNoteTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.firstLineIsTitle = firstLineIsTitle
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(firstLineIsTitle ? "Note document" : "Meeting notes")
        textView.textStorage?.setAttributedString(MarkdownRich.attributed(from: markdown, firstLineIsTitle: firstLineIsTitle))
        textView.typingAttributes = textView.baseAttributes(title: firstLineIsTitle && markdown.isEmpty)
        textView.installFormatBar()
        session?.textView = textView
        context.coordinator.lastMarkdown = markdown
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        textView.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? RichNoteTextView else { return }
        session?.textView = textView
        if context.coordinator.lastMarkdown != markdown {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(MarkdownRich.attributed(from: markdown, firstLineIsTitle: firstLineIsTitle))
            context.coordinator.lastMarkdown = markdown
            textView.setSelectedRange(NSRange(location: min(selection.location, (textView.string as NSString).length), length: 0))
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMarkdownEditor
        var lastMarkdown = ""
        init(_ parent: RichMarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? RichNoteTextView else { return }
            view.enforceTitleStyling()
            lastMarkdown = MarkdownRich.markdown(from: view.attributedString(), firstLineIsTitle: view.firstLineIsTitle)
            parent.markdown = lastMarkdown
            view.updateSlashMenu()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RichNoteTextView)?.updateFormatBar()
        }
    }
}

final class RichNoteTextView: NSTextView {
    var firstLineIsTitle = true
    var placeholder = "Start writing…"
    private var formatBar: NSHostingView<FormatBar>?
    private var slashMenu: NSHostingView<BlockPicker>?
    private var slashRange: NSRange?
    private var choices: [DocumentBlock] = []
    private var choiceIndex = 0
    private var linkPopover: NSPopover?
    private var adjustingColumn = false

    override func setFrameSize(_ newSize: NSSize) {
        guard !adjustingColumn else { super.setFrameSize(newSize); return }
        adjustingColumn = true
        defer { adjustingColumn = false }
        super.setFrameSize(newSize)
        let inset = max(MM.Document.margin, (newSize.width - MM.Document.columnWidth) / 2)
        let desired = NSSize(width: inset, height: firstLineIsTitle ? 32 : 20)
        if textContainerInset != desired { textContainerInset = desired }
        // widthTracksTextView owns the container. Setting both sizes here
        // makes TextKit feed container resizing back into this method.
        updateFormatBar()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: firstLineIsTitle ? MarkdownRich.titleFont : MarkdownRich.bodyFont(bold: false), .foregroundColor: NSColor.tertiaryLabelColor]
            ((firstLineIsTitle ? "Untitled note" : placeholder) as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
        }
    }

    func baseAttributes(title: Bool = false, prefix: String = "") -> [NSAttributedString.Key: Any] {
        let sample = NSMutableAttributedString(string: " ", attributes: [.manBlock: prefix])
        MarkdownRich.style(sample, title: title)
        return sample.attributes(at: 0, effectiveRange: nil)
    }

    private func isTitle(_ range: NSRange) -> Bool {
        firstLineIsTitle && range.location <= (string as NSString).range(of: "\n").location
    }

    /// Preserve structure and inline traits while applying the page typography.
    func enforceTitleStyling() {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        var location = 0
        storage.beginEditing()
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let line = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            let prefix = line.attribute(.manBlock, at: 0, effectiveRange: nil) as? String ?? ""
            line.addAttribute(.manBlock, value: prefix, range: NSRange(location: 0, length: line.length))
            MarkdownRich.style(line, title: firstLineIsTitle && location == 0)
            line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attrs, run, _ in
                storage.setAttributes(attrs, range: NSRange(location: location + run.location, length: run.length))
            }
            location = NSMaxRange(range)
        }
        storage.endEditing()
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), isEditable {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": toggleBoldSelection(); return true
            case "i": toggleItalicSelection(); return true
            case "u": toggleUnderlineSelection(); return true
            case "k": editLink(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if slashRange != nil, !choices.isEmpty {
            switch event.keyCode {
            case 125: choiceIndex = (choiceIndex + 1) % choices.count; refreshSlashPicker(); return
            case 126: choiceIndex = (choiceIndex + choices.count - 1) % choices.count; refreshSlashPicker(); return
            case 36: applyBlock(choices[choiceIndex]); return
            case 53: dismissSlashMenu(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if let _ = slashRange, !choices.isEmpty { applyBlock(choices[choiceIndex]); return }
        let selection = selectedRange()
        let ns = string as NSString
        let range = ns.lineRange(for: selection)
        let prefix = range.location < ns.length ? textStorage?.attribute(.manBlock, at: range.location, effectiveRange: nil) as? String ?? "" : ""
        let parts = MarkdownRich.block(prefix + "content")
        let current = ns.substring(with: range).trimmingCharacters(in: .newlines)
        if !parts.display.isEmpty, current.trimmingCharacters(in: .whitespaces) == parts.display.trimmingCharacters(in: .whitespaces) {
            applyBlock(.text)
            return
        }
        var next = prefix
        if prefix.trimmingCharacters(in: .whitespaces).hasPrefix("#") || isTitle(selection) { next = "" }
        if next.lowercased().contains("[x]") { next = next.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive) }
        if let match = try? NSRegularExpression(pattern: #"\d+"#).firstMatch(in: next, range: NSRange(next.startIndex..., in: next)),
           let number = Int((next as NSString).substring(with: match.range)) {
            next = (next as NSString).replacingCharacters(in: match.range, with: String(number + 1))
        }
        let attrs = baseAttributes(prefix: next)
        let insertion = NSAttributedString(string: "\n" + MarkdownRich.block(next + "content").display, attributes: attrs)
        insertText(insertion, replacementRange: selection)
        typingAttributes = attrs
    }

    override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        copyMarkdown(to: .general)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    func copyMarkdown(to pasteboard: NSPasteboard) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let copy = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        let paragraph = (string as NSString).lineRange(for: range)
        if range.location != paragraph.location || NSMaxRange(range) < NSMaxRange(paragraph) - 1 {
            copy.removeAttribute(.manBlock, range: NSRange(location: 0, length: copy.length))
        }
        let type = NSPasteboard.PasteboardType("com.muckstack.myman.markdown")
        pasteboard.addTypes([type], owner: nil)
        pasteboard.setString(MarkdownRich.markdown(from: copy, firstLineIsTitle: false), forType: type)
    }

    func paste(from pasteboard: NSPasteboard) {
        if let markdown = pasteboard.string(forType: NSPasteboard.PasteboardType("com.muckstack.myman.markdown")) {
            insertText(MarkdownRich.attributed(from: markdown, firstLineIsTitle: false), replacementRange: selectedRange())
            return
        }
        // Foreign RTF attributes aren't our Markdown model. Import plain text
        // intentionally, preserving the current block and inline formatting.
        guard let text = pasteboard.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        if index < ns.length {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            let prefix = textStorage?.attribute(.manBlock, at: line.location, effectiveRange: nil) as? String ?? ""
            let marker = MarkdownRich.block(prefix + "content").display
            if prefix.contains("["), index < line.location + (marker as NSString).length {
                toggleChecklist(at: line)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func toggleChecklist(at line: NSRange) {
        guard let storage = textStorage else { return }
        let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: line))
        let prefix = content.attribute(.manBlock, at: 0, effectiveRange: nil) as? String ?? ""
        guard prefix.contains("[") else { return }
        let checked = prefix.contains("[ ]")
        let next = checked ? prefix.replacingOccurrences(of: "[ ]", with: "[x]") : prefix.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive)
        let marker = (content.string as NSString).range(of: checked ? "☐" : "☑")
        if marker.location != NSNotFound { content.replaceCharacters(in: marker, with: checked ? "☑" : "☐") }
        content.addAttribute(.manBlock, value: next, range: NSRange(location: 0, length: content.length))
        replace(line, with: content)
    }

    func toggleBoldSelection() { toggle(.manBold) }
    func toggleItalicSelection() { toggle(.manItalic) }
    func toggleUnderlineSelection() { toggle(.underlineStyle) }
    func toggleStrikeSelection() { toggle(.strikethroughStyle) }

    private func toggle(_ key: NSAttributedString.Key) {
        let range = selectedRange()
        if range.length == 0 {
            var attrs = typingAttributes
            if attrs[key] != nil { attrs.removeValue(forKey: key) } else { attrs[key] = key == .manBold || key == .manItalic ? true : 1 }
            let sample = NSMutableAttributedString(string: " ", attributes: attrs)
            MarkdownRich.style(sample, title: isTitle(range))
            typingAttributes = sample.attributes(at: 0, effectiveRange: nil)
            return
        }
        let content = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        var allOn = true
        content.enumerateAttribute(key, in: NSRange(location: 0, length: content.length)) { value, _, _ in if value == nil { allOn = false } }
        if allOn { content.removeAttribute(key, range: NSRange(location: 0, length: content.length)) }
        else { content.addAttribute(key, value: key == .manBold || key == .manItalic ? true : 1, range: NSRange(location: 0, length: content.length)) }
        replace(range, with: content)
    }

    private func replace(_ range: NSRange, with content: NSAttributedString) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        window?.makeFirstResponder(self)
        let previous = storage.attributedSubstring(from: range)
        let replacementRange = NSRange(location: range.location, length: content.length)
        breakUndoCoalescing()
        undoManager?.registerUndo(withTarget: self) { view in view.replace(replacementRange, with: previous) }
        // Direct attributed replacement is deliberate: insertText can retain
        // the old link when the characters themselves have not changed.
        typingAttributes = baseAttributes(title: isTitle(range))
        storage.replaceCharacters(in: range, with: content)
        didChangeText()
        setSelectedRange(replacementRange)
        updateFormatBar()
    }

    func applyBlock(_ block: DocumentBlock) {
        let selection = selectedRange()
        let ns = string as NSString
        let range = ns.lineRange(for: selection)
        let existing = attributedString().attributedSubstring(from: range)
        let raw = MarkdownRich.markdown(from: existing, firstLineIsTitle: false)
        let lines = raw.components(separatedBy: "\n")
        let rewritten = lines.enumerated().map { index, line -> String in
            if index == lines.count - 1, line.isEmpty, raw.hasSuffix("\n") { return "" }
            let body = slashRange != nil ? "" : MarkdownRich.block(line).body
            let prefix = block == .numbered ? "\(index + 1). " : block.prefix
            return prefix + body
        }.joined(separator: "\n")
        let content = MarkdownRich.attributed(from: rewritten, firstLineIsTitle: firstLineIsTitle && range.location == 0)
        // Empty blocks still need a visible marker/caret with block attributes.
        dismissSlashMenu()
        replace(range, with: content)
        let caret = range.location + content.length - (content.string.hasSuffix("\n") ? 1 : 0)
        setSelectedRange(NSRange(location: caret, length: 0))
        typingAttributes = baseAttributes(title: firstLineIsTitle && range.location == 0, prefix: block.prefix)
    }

    func editLink() {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let current = textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LinkEditor(initial: current?.absoluteString ?? "") { [weak self, weak popover] target in
            self?.setLink(target, range: range)
            popover?.close()
        })
        linkPopover = popover
        let rect = localRect(for: range)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    func setLink(_ target: String, range: NSRange) {
        guard NSMaxRange(range) <= (string as NSString).length else { return }
        let content = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { content.removeAttribute(.link, range: NSRange(location: 0, length: content.length)) }
        else {
            guard let url = URL(string: trimmed), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            content.addAttribute(.link, value: url, range: NSRange(location: 0, length: content.length))
        }
        replace(range, with: content)
    }

    private func localRect(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        return convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
    }

    func installFormatBar() {
        let bar = NSHostingView(rootView: makeFormatBar())
        bar.isHidden = true
        addSubview(bar)
        formatBar = bar
    }

    private func makeFormatBar() -> FormatBar {
        FormatBar(onBold: { [weak self] in self?.toggleBoldSelection() },
                  onItalic: { [weak self] in self?.toggleItalicSelection() },
                  onUnderline: { [weak self] in self?.toggleUnderlineSelection() },
                  onStrike: { [weak self] in self?.toggleStrikeSelection() },
                  onLink: { [weak self] in self?.editLink() })
    }

    func updateFormatBar() {
        guard let bar = formatBar else { return }
        let range = selectedRange()
        guard range.length > 0, window != nil, slashRange == nil else { bar.isHidden = true; return }
        let rect = localRect(for: range)
        let size = NSSize(width: 180, height: 36)
        let visible = visibleRect
        let above = rect.minY - size.height - 8
        bar.frame = NSRect(x: min(max(visible.minX + 8, rect.midX - size.width / 2), max(8, visible.maxX - size.width - 8)), y: above < visible.minY ? rect.maxY + 8 : above, width: size.width, height: size.height)
        bar.isHidden = false
    }

    func updateSlashMenu() {
        let selection = selectedRange()
        guard selection.length == 0, !isTitle(selection) else { dismissSlashMenu(); return }
        let ns = string as NSString
        let line = ns.lineRange(for: selection)
        let before = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        guard before.hasPrefix("/"), before.count < 24, !before.contains(" "), ns.substring(with: line).trimmingCharacters(in: .newlines) == before else { dismissSlashMenu(); return }
        let query = before.dropFirst().lowercased()
        choices = DocumentBlock.allCases.filter { query.isEmpty || $0.label.lowercased().contains(query) || $0.rawValue.contains(query) || ($0 == .checklist && query == "todo") }
        guard !choices.isEmpty else { dismissSlashMenu(); return }
        slashRange = NSRange(location: line.location, length: selection.location - line.location)
        choiceIndex = min(choiceIndex, choices.count - 1)
        refreshSlashPicker()
    }

    private func refreshSlashPicker() {
        let view = BlockPicker(choices: choices, selected: choiceIndex) { [weak self] block in self?.applyBlock(block) }
        if slashMenu == nil { let menu = NSHostingView(rootView: view); addSubview(menu); slashMenu = menu }
        slashMenu?.rootView = view
        let size = NSSize(width: 240, height: CGFloat(choices.count * 34 + 16))
        let rect = localRect(for: selectedRange())
        let y = rect.maxY + size.height + 8 > visibleRect.maxY ? max(visibleRect.minY, rect.minY - size.height - 8) : rect.maxY + 8
        slashMenu?.frame = NSRect(x: min(rect.minX, max(0, bounds.width - size.width - 8)), y: y, width: size.width, height: size.height)
        formatBar?.isHidden = true
    }

    private func dismissSlashMenu() { slashRange = nil; slashMenu?.removeFromSuperview(); slashMenu = nil; choiceIndex = 0 }
}

private struct FormatBar: View {
    var onBold: () -> Void
    var onItalic: () -> Void
    var onUnderline: () -> Void
    var onStrike: () -> Void
    var onLink: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            button("bold", "Bold (⌘B)", onBold)
            button("italic", "Italic (⌘I)", onItalic)
            button("underline", "Underline (⌘U)", onUnderline)
            button("strikethrough", "Strikethrough", onStrike)
            button("link", "Link (⌘K)", onLink)
        }
        .padding(4)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 1))
    }
    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(MM.Fonts.secondary).frame(width: 30, height: 28).clickable() }
            .buttonStyle(.plain).foregroundStyle(MM.Colors.textPrimary).help(label).accessibilityLabel(label)
    }
}

private struct BlockPicker: View {
    let choices: [DocumentBlock]
    let selected: Int
    var choose: (DocumentBlock) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, block in
                Button { choose(block) } label: {
                    HStack(spacing: MM.Layout.spacing) {
                        Image(systemName: block.symbol).frame(width: 22)
                        Text(block.label)
                        Spacer()
                        if index == selected { Text("↵").foregroundStyle(MM.Colors.textTertiary) }
                    }
                    .font(MM.Fonts.secondary).padding(.horizontal, MM.Layout.spacing).frame(height: 34)
                    .background(index == selected ? MM.Colors.border : .clear).clickable()
                }.buttonStyle(.plain)
            }
        }.padding(8).foregroundStyle(MM.Colors.textPrimary)
            .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 1))
    }
}

private struct LinkEditor: View {
    let initial: String
    var save: (String) -> Void
    @State private var url = ""
    @FocusState private var focused: Bool
    private var valid: Bool { url.isEmpty || ["https", "http", "mailto"].contains(URL(string: url)?.scheme?.lowercased() ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Link").font(MM.Fonts.secondary)
            TextField("https://example.com", text: $url).textFieldStyle(.roundedBorder).focused($focused).onSubmit { if valid { save(url) } }
            HStack {
                Button("Remove link") { save("") }.buttonStyle(.plain).clickable()
                Spacer()
                Button("Apply") { save(url) }.disabled(!valid).clickable()
            }.font(MM.Fonts.secondary)
        }.padding(MM.Layout.padding).frame(width: 300)
            .onAppear { url = initial; focused = true }
    }
}
