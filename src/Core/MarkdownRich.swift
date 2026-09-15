import AppKit

extension NSAttributedString.Key {
    static let manBold = Self("man.bold")
    static let manItalic = Self("man.italic")
    static let manCode = Self("man.code")
    static let manBlock = Self("man.block")
}

/// Markdown remains the storage format. Structure is explicit metadata,
/// independent of typography, so changing a font cannot change a document.
enum MarkdownRich {
    static let bodySize = MM.Document.bodySize
    static let titleSize = MM.Document.titleSize
    static let headingSize: CGFloat = 24
    static let bulletPrefix = "•  "

    static func bodyFont(bold: Bool) -> NSFont { font(bold: bold, italic: false, title: false) }
    static var titleFont: NSFont { font(bold: false, italic: false, title: true) }
    static func font(bold: Bool, italic: Bool, title: Bool, heading: Bool = false) -> NSFont {
        MM.Fonts.native(title ? titleSize : heading ? headingSize : bodySize,
                        bold || title || heading ? .semiBold : .regular, italic: italic)
    }

    static func plainText(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { parseInline(block($0).body, loadImages: false).string }.joined(separator: "\n")
    }

    static func block(_ line: String) -> (prefix: String, display: String, body: String) {
        let pattern = #"^(\s*(?:#{1,3} |[-*] \[[ xX]\] |[-*] |\d+\. |> ))"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return ("", "", line)
        }
        let ns = line as NSString
        let prefix = ns.substring(with: match.range)
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let indent = String(prefix.prefix(while: { $0 == " " || $0 == "\t" }))
        let marker: String
        if trimmed.contains("[ ]") { marker = "☐  " }
        else if trimmed.lowercased().contains("[x]") { marker = "☑  " }
        else if trimmed == "-" || trimmed == "*" { marker = bulletPrefix }
        else if trimmed == ">" { marker = "│  " }
        else if trimmed.first?.isNumber == true { marker = trimmed + "  " }
        else { marker = "" }
        return (prefix, indent + marker, ns.substring(from: NSMaxRange(match.range)))
    }

    static func attributed(from markdown: String, firstLineIsTitle: Bool = true, assets: DocumentAssets = .shared) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var fenced = false
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            if !fenced, let parsed = DocumentTable.parse(lines, at: index) {
                result.append(parsed.table.attributed(assets: assets)); index = parsed.end; continue
            }
            let fence = raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") || raw.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            let literal = fenced || fence
            let parts = literal ? (prefix: "", display: "", body: raw) : block(raw)
            let line = NSMutableAttributedString(string: parts.display, attributes: [.font: bodyFont(bold: false), .foregroundColor: NSColor.secondaryLabelColor])
            if literal {
                line.append(NSAttributedString(string: parts.body, attributes: [.font: NSFont.monospacedSystemFont(ofSize: bodySize - 2, weight: .regular), .manCode: "fenced"]))
            } else {
                line.append(parseInline(parts.body, assets: assets))
            }
            if index < lines.count - 1 { line.append(NSAttributedString(string: "\n")) }
            line.addAttribute(.manBlock, value: parts.prefix, range: NSRange(location: 0, length: line.length))
            style(line, title: firstLineIsTitle && index == 0)
            result.append(line)
            if fence { fenced.toggle() }
            index += 1
        }
        return result
    }

    static func parseInline(_ source: String, depth: Int = 0, assets: DocumentAssets = .shared, loadImages: Bool = true) -> NSMutableAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont(bold: false), .foregroundColor: NSColor.textColor]
        guard depth < 8 else { return NSMutableAttributedString(string: source, attributes: base) }
        let output = NSMutableAttributedString()
        let pattern = #"(!\[[^\]\n]*\]\([^\)\n]+\)|`[^`\n]+`|\[[^\]\n]+\]\((?:\\.|[^)\n])+\)|<u>.*?</u>|\*\*\*.+?\*\*\*|\*\*.+?\*\*|~~.+?~~|\*[^*\n]+\*)"#
        let ns = source as NSString
        var cursor = 0
        let matches = (try? NSRegularExpression(pattern: pattern).matches(in: source, range: NSRange(location: 0, length: ns.length))) ?? []
        for match in matches {
            output.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: base))
            let token = ns.substring(with: match.range)
            var attributes: [NSAttributedString.Key: Any] = [:]
            let content: String
            if token.hasPrefix("!["), let boundary = token.range(of: "](") {
                let alt = String(token[token.index(token.startIndex, offsetBy: 2)..<boundary.lowerBound])
                let target = String(token[boundary.upperBound...].dropLast())
                if !loadImages {
                    output.append(NSAttributedString(string: alt, attributes: base))
                } else if let url = assets.resolve(target) {
                    output.append(NSAttributedString(attachment: DocumentImageAttachment(markdown: token, url: url, alternativeText: alt)))
                } else { output.append(NSAttributedString(string: token, attributes: base)) }
                cursor = NSMaxRange(match.range); continue
            } else if token.hasPrefix("`") {
                content = String(token.dropFirst().dropLast()); attributes[.manCode] = "inline"
            } else if token.hasPrefix("["), let boundary = token.range(of: "](") {
                let target = String(token[boundary.upperBound...].dropLast()).replacingOccurrences(of: "\\)", with: ")").replacingOccurrences(of: "\\(", with: "(")
                // Unsafe or unsupported links remain literal, never actionable.
                guard let url = URL(string: target), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                    output.append(NSAttributedString(string: token, attributes: base)); cursor = NSMaxRange(match.range); continue
                }
                content = String(token[token.index(after: token.startIndex)..<boundary.lowerBound]); attributes[.link] = url
            } else if token.hasPrefix("<u>") {
                content = String(token.dropFirst(3).dropLast(4)); attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else if token.hasPrefix("***") {
                content = String(token.dropFirst(3).dropLast(3)); attributes[.manBold] = true; attributes[.manItalic] = true
            } else if token.hasPrefix("**") {
                content = String(token.dropFirst(2).dropLast(2)); attributes[.manBold] = true
            } else if token.hasPrefix("~~") {
                content = String(token.dropFirst(2).dropLast(2)); attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            } else {
                content = String(token.dropFirst().dropLast()); attributes[.manItalic] = true
            }
            let inner = attributes[.manCode] != nil ? NSMutableAttributedString(string: content, attributes: base) : parseInline(content, depth: depth + 1, assets: assets, loadImages: loadImages)
            inner.addAttributes(attributes, range: NSRange(location: 0, length: inner.length))
            output.append(inner)
            cursor = NSMaxRange(match.range)
        }
        output.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base))
        return output
    }

    /// Apply presentation without erasing semantic attributes or changing text.
    static func style(_ text: NSMutableAttributedString, title: Bool = false) {
        guard text.length > 0 else { return }
        let whole = NSRange(location: 0, length: text.length)
        let rawPrefix = text.attribute(.manBlock, at: 0, effectiveRange: nil) as? String ?? ""
        let prefix = rawPrefix.trimmingCharacters(in: .whitespaces)
        // Two leading spaces per nesting level, as the markdown stores it.
        let nesting = CGFloat(rawPrefix.prefix(while: { $0 == " " || $0 == "\t" }).count / 2)
        let heading = prefix.hasPrefix("#")
        let size: CGFloat = title ? titleSize : prefix == "#" ? 28 : prefix == "##" ? 24 : prefix == "###" ? 20 : bodySize
        let existingParagraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tableCell = existingParagraph?.textBlocks.first as? NSTextTableBlock
        let paragraph = NSMutableParagraphStyle()
        if let existingParagraph, tableCell != nil {
            paragraph.textBlocks = existingParagraph.textBlocks
            paragraph.alignment = existingParagraph.alignment
        }
        paragraph.lineSpacing = MM.Document.lineSpacing
        paragraph.paragraphSpacing = title ? 24 : MM.Document.paragraphSpacing
        paragraph.paragraphSpacingBefore = heading && !title ? 12 : 0
        if tableCell != nil { paragraph.paragraphSpacing = 0; paragraph.lineSpacing = 3 }
        if prefix.hasPrefix("-") || prefix.hasPrefix("*") || prefix.first?.isNumber == true || prefix == ">" {
            // The display text keeps its leading spaces, so only wrapped
            // lines need the extra hang to sit under the first word.
            paragraph.headIndent = 24 + nesting * 7
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        text.enumerateAttributes(in: whole) { attributes, range, _ in
            let code = attributes[.manCode] as? String
            let bold = attributes[.manBold] as? Bool == true
            let italic = attributes[.manItalic] as? Bool == true
            text.addAttribute(.font, value: code != nil ? NSFont.monospacedSystemFont(ofSize: bodySize - 2, weight: bold ? .semibold : .regular) : MM.Fonts.native(tableCell != nil ? MM.Fonts.tableSize : size, bold || title || heading || tableCell?.startingRow == 0 ? .semiBold : .regular, italic: italic), range: range)
            text.addAttribute(.foregroundColor, value: prefix == ">" ? NSColor.secondaryLabelColor : NSColor.textColor, range: range)
            if code == "inline" { text.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range) }
        }
    }

    static func inlineMarkdown(_ content: NSAttributedString) -> String {
        var output = ""
        var active: [(key: String, open: String, close: String)] = []
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
                if let image = attributes[.attachment] as? DocumentImageAttachment {
                    output += active.reversed().map(\.close).joined() + image.markdown
                    active = []; return
                }
                let text = (content.string as NSString).substring(with: range)
                var marks: [(key: String, open: String, close: String)] = []
                if let link = attributes[.link] as? URL {
                    let url = link.absoluteString.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
                    marks.append(("link:" + url, "[", "](\(url))"))
                }
                if (attributes[.underlineStyle] as? Int ?? 0) != 0 { marks.append(("underline", "<u>", "</u>")) }
                if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { marks.append(("strike", "~~", "~~")) }
                if attributes[.manBold] as? Bool == true { marks.append(("bold", "**", "**")) }
                if attributes[.manItalic] as? Bool == true { marks.append(("italic", "*", "*")) }
                if attributes[.manCode] as? String == "inline" { marks.append(("code", "`", "`")) }
                var common = 0
                while common < min(active.count, marks.count), active[common].key == marks[common].key { common += 1 }
                output += active.dropFirst(common).reversed().map(\.close).joined()
                output += marks.dropFirst(common).map(\.open).joined()
                output += text
                active = marks
            }
            output += active.reversed().map(\.close).joined()
        return output
    }

    static func markdown(from attributed: NSAttributedString, firstLineIsTitle: Bool = true) -> String {
        let full = attributed.string as NSString
        var output = "", location = 0
        while location < full.length {
            if let table = DocumentTable.selection(in: attributed, at: location) {
                output += table.markdown(in: attributed)
                location = NSMaxRange(table.range)
                if location < full.length, !output.hasSuffix("\n") { output += "\n" }
                continue
            }
            let newline = full.range(of: "\n", range: NSRange(location: location, length: full.length - location))
            let end = newline.location == NSNotFound ? full.length : newline.location
            let line = attributed.attributedSubstring(from: NSRange(location: location, length: end - location))
            let prefix = attributed.attribute(.manBlock, at: location, effectiveRange: nil) as? String ?? ""
            let display = block(prefix + "content").display
            let start = !display.isEmpty && line.string.hasPrefix(display) ? (display as NSString).length : 0
            output += prefix + inlineMarkdown(line.attributedSubstring(from: NSRange(location: start, length: line.length - start)))
            if newline.location == NSNotFound { break }
            output += "\n"; location = end + 1
        }
        return output
    }
}
