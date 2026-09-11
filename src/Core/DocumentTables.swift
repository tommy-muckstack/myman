import AppKit
import SwiftUI

extension NSAttributedString.Key { static let manTable = Self("man.table") }

final class DocumentTableMetadata: NSObject {
    let id = UUID().uuidString
    let originalMarkdown: String
    var originalCells: [[String]]
    let alignments: [NSTextAlignment]
    init(original: String, cells: [[String]], alignments: [NSTextAlignment]) {
        originalMarkdown = original; originalCells = cells; self.alignments = alignments
    }
}

/// Native text-table paragraphs retain selection, inline formatting, spelling,
/// and accessibility. Markdown cells remain the durable representation.
struct DocumentTable {
    static let maximumColumns = 6
    static let maximumRows = 100
    var cells: [[String]]
    var alignments: [NSTextAlignment] = []
    var originalMarkdown = ""

    static func split(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        var result: [String] = [], cell = "", escaped = false, code = false
        for ch in trimmed.dropFirst().dropLast() {
            if escaped { cell.append(ch); escaped = false; continue }
            if ch == "\\" { cell.append(ch); escaped = true; continue }
            if ch == "`" { code.toggle() }
            if ch == "|", !code { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(ch) }
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }
    static func parse(_ lines: [String], at start: Int) -> (table: DocumentTable, end: Int)? {
        guard start + 1 < lines.count, let header = split(lines[start]), let rules = split(lines[start + 1]),
              !header.isEmpty, header.count <= maximumColumns, rules.count == header.count,
              rules.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        var rows = [header]; var end = start + 2
        while end < lines.count, rows.count < maximumRows, let row = split(lines[end]), row.count == header.count {
            rows.append(row); end += 1
        }
        let alignments: [NSTextAlignment] = rules.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left }
        let raw = lines[start..<end].joined(separator: "\n") + (end < lines.count ? "\n" : "")
        return (DocumentTable(cells: rows, alignments: alignments, originalMarkdown: raw), end)
    }
    static func fromTSV(_ text: String) -> DocumentTable? {
        let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: .newlines)
        guard (2...maximumRows).contains(lines.count) else { return nil }
        let cells = lines.map { $0.components(separatedBy: "\t") }
        guard let count = cells.first?.count, (2...maximumColumns).contains(count), cells.allSatisfy({ $0.count == count }) else { return nil }
        return DocumentTable(cells: cells.map { $0.map { $0.replacingOccurrences(of: "|", with: "\\|") } })
    }
    var markdown: String {
        guard let columns = cells.first?.count, columns > 0 else { return "" }
        func row(_ values: [String]) -> String { "| " + values.joined(separator: " | ") + " |" }
        let rules = (0..<columns).map { index -> String in
            let alignment = index < alignments.count ? alignments[index] : .left
            return alignment == .center ? ":---:" : alignment == .right ? "---:" : "---"
        }
        return ([row(cells[0]), row(rules)] + cells.dropFirst().map(row)).joined(separator: "\n")
    }
    func attributed(assets: DocumentAssets = .shared) -> NSAttributedString {
        let output = NSMutableAttributedString()
        guard let columns = cells.first?.count, columns > 0 else { return output }
        let metadata = DocumentTableMetadata(original: originalMarkdown, cells: cells, alignments: alignments)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        for (rowIndex, row) in cells.enumerated() {
            for (column, source) in row.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                cell.setWidth(MM.Layout.spacing, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(MM.Colors.border))
                cell.verticalAlignment = .topAlignment
                if rowIndex == 0 { cell.backgroundColor = NSColor(MM.Colors.surface) }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [cell]
                paragraph.alignment = column < alignments.count ? alignments[column] : .left
                let content = MarkdownRich.parseInline(source.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "<br>", with: "\u{2028}"), assets: assets)
                content.append(NSAttributedString(string: "\n"))
                content.addAttributes([.manTable: metadata, .manBlock: "", .paragraphStyle: paragraph], range: NSRange(location: 0, length: content.length))
                MarkdownRich.style(content)
                output.append(content)
            }
        }
        // Compare the normalized representation, preserving the user's exact
        // original spacing/alignment syntax until they actually edit a cell.
        metadata.originalCells = Self.selection(in: output, at: 0)?.model(in: output).cells ?? cells
        return output
    }

    struct Cell {
        let range: NSRange
        let row: Int
        let column: Int
    }
    struct Selection {
        let range: NSRange
        let metadata: DocumentTableMetadata
        let cells: [Cell]
        let current: Cell
        var columns: Int { (cells.map(\.column).max() ?? 0) + 1 }
        var rows: Int { (cells.map(\.row).max() ?? 0) + 1 }
        func model(in text: NSAttributedString) -> DocumentTable {
            var result = Array(repeating: Array(repeating: "", count: columns), count: rows)
            for cell in cells {
                let length = max(0, cell.range.length - (text.attributedSubstring(from: cell.range).string.hasSuffix("\n") ? 1 : 0))
                let value = MarkdownRich.inlineMarkdown(text.attributedSubstring(from: NSRange(location: cell.range.location, length: length)))
                    .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\u{2028}", with: "<br>")
                result[cell.row][cell.column] += value
            }
            return DocumentTable(cells: result, alignments: metadata.alignments)
        }
        func markdown(in text: NSAttributedString) -> String {
            let model = model(in: text)
            return !metadata.originalMarkdown.isEmpty && model.cells == metadata.originalCells ? metadata.originalMarkdown : model.markdown + "\n"
        }
    }
    static func selection(in text: NSAttributedString, at index: Int) -> Selection? {
        guard index >= 0, index < text.length,
              let metadata = text.attribute(.manTable, at: index, effectiveRange: nil) as? DocumentTableMetadata else { return nil }
        var tableRange = NSRange(location: 0, length: 0)
        _ = text.attribute(.manTable, at: index, longestEffectiveRange: &tableRange, in: NSRange(location: 0, length: text.length))
        var cells: [Cell] = []; var location = tableRange.location
        let string = text.string as NSString
        while location < NSMaxRange(tableRange) {
            let range = NSIntersectionRange(string.paragraphRange(for: NSRange(location: location, length: 0)), tableRange)
            guard range.length > 0 else { break }
            if let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
               let block = style.textBlocks.first as? NSTextTableBlock {
                cells.append(Cell(range: range, row: block.startingRow, column: block.startingColumn))
            }
            location = NSMaxRange(range)
        }
        guard let current = cells.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        return Selection(range: tableRange, metadata: metadata, cells: cells, current: current)
    }
}
