import AppKit
import UniformTypeIdentifiers

extension RichNoteTextView {
    /// Preserve cell boundaries when replacing a selection spanning cells.
    /// Selecting a whole table still removes the table normally.
    func replaceAcrossTableCells(_ value: Any, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= attributedString().length else { return false }
        let source = attributedString()
        let boundaries = NSMutableAttributedString()
        var location = range.location
        while location < NSMaxRange(range) {
            guard let table = DocumentTable.selection(in: source, at: location) else { location += 1; continue }
            if NSIntersectionRange(range, table.range) != table.range {
                for cell in table.cells {
                    let end = NSMaxRange(cell.range) - 1
                    if NSLocationInRange(end, range), (source.string as NSString).substring(with: NSRange(location: end, length: 1)) == "\n" {
                        boundaries.append(source.attributedSubstring(from: NSRange(location: end, length: 1)))
                    }
                }
            }
            location = NSMaxRange(table.range)
        }
        guard boundaries.length > 0 else { return false }
        let insertion: NSMutableAttributedString
        if let attributed = value as? NSAttributedString { insertion = NSMutableAttributedString(attributedString: attributed) }
        else { insertion = NSMutableAttributedString(string: value as? String ?? "", attributes: typingAttributes) }
        if let table = DocumentTable.selection(in: source, at: range.location), insertion.length > 0 {
            let attrs = source.attributes(at: table.current.range.location, effectiveRange: nil)
            for key in [NSAttributedString.Key.manTable, .paragraphStyle, .manBlock] {
                if let value = attrs[key] { insertion.addAttribute(key, value: value, range: NSRange(location: 0, length: insertion.length)) }
            }
        }
        let count = insertion.length
        insertion.append(boundaries)
        replace(range, with: insertion)
        setSelectedRange(NSRange(location: range.location + count, length: 0))
        return true
    }

    var currentTable: DocumentTable.Selection? {
        DocumentTable.selection(in: attributedString(), at: selectedRange().location)
    }

    func insertTable(rows: Int = 3, columns: Int = 2) {
        let rows = min(DocumentTable.maximumRows, max(2, rows))
        let columns = min(DocumentTable.maximumColumns, max(1, columns))
        var cells = Array(repeating: Array(repeating: "", count: columns), count: rows)
        cells[0] = (0..<columns).map { "Column \($0 + 1)" }
        insertTable(DocumentTable(cells: cells))
    }
    func insertTable(_ table: DocumentTable) {
        let range = selectedRange()
        let content = NSMutableAttributedString()
        if range.location > 0, (string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) != "\n" {
            content.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
        }
        let start = range.location + content.length
        content.append(table.attributed(assets: assets))
        content.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
        replace(range, with: content)
        if let selection = DocumentTable.selection(in: attributedString(), at: start) {
            selectTableCell(selection.current)
        }
    }
    func selectTableCell(_ cell: DocumentTable.Cell) {
        setSelectedRange(NSRange(location: cell.range.location, length: max(0, cell.range.length - 1)))
        typingAttributes = attributedString().attributes(at: cell.range.location, effectiveRange: nil)
        scrollRangeToVisible(selectedRange())
    }
    @discardableResult func moveTableCell(backward: Bool) -> Bool {
        guard let table = currentTable, let index = table.cells.firstIndex(where: { $0.range == table.current.range }) else { return false }
        let next = index + (backward ? -1 : 1)
        if next < 0 { return true }
        if next < table.cells.count { selectTableCell(table.cells[next]); return true }
        if table.rows < DocumentTable.maximumRows {
            var model = table.model(in: attributedString())
            model.cells.append(Array(repeating: "", count: table.columns))
            replaceTable(table, with: model, row: table.rows, column: 0)
        } else { exitTable() }
        return true
    }
    func exitTable() {
        guard let table = currentTable else { return }
        var end = NSMaxRange(table.range)
        if end >= (string as NSString).length {
            replace(NSRange(location: end, length: 0), with: NSAttributedString(string: "\n", attributes: baseAttributes()))
        }
        end = min(end, (string as NSString).length)
        setSelectedRange(NSRange(location: end, length: 0))
        typingAttributes = baseAttributes()
        updateFormatBar()
    }
    func replaceTable(_ table: DocumentTable.Selection, with model: DocumentTable, row: Int, column: Int) {
        replace(table.range, with: model.attributed(assets: assets))
        if let updated = DocumentTable.selection(in: attributedString(), at: table.range.location),
           let cell = updated.cells.first(where: { $0.row == row && $0.column == column }) { selectTableCell(cell) }
    }
    func editTable(_ operation: String) {
        guard let table = currentTable else { return }
        var model = table.model(in: attributedString())
        var row = table.current.row, column = table.current.column
        switch operation {
        case "row" where table.rows < DocumentTable.maximumRows:
            row += 1; model.cells.insert(Array(repeating: "", count: table.columns), at: row)
        case "column" where table.columns < DocumentTable.maximumColumns:
            column += 1
            for index in model.cells.indices { model.cells[index].insert("", at: column) }
            while model.alignments.count < table.columns { model.alignments.append(.left) }
            model.alignments.insert(.left, at: column)
        case "deleteRow" where table.rows > 1:
            model.cells.remove(at: row); row = min(row, model.cells.count - 1)
        case "deleteColumn" where table.columns > 1:
            for index in model.cells.indices { model.cells[index].remove(at: column) }
            if column < model.alignments.count { model.alignments.remove(at: column) }
            column = min(column, table.columns - 2)
        case "remove":
            replace(table.range, with: NSAttributedString(string: "", attributes: baseAttributes()))
            setSelectedRange(NSRange(location: table.range.location, length: 0)); typingAttributes = baseAttributes(); return
        case "leave": exitTable(); return
        default: return
        }
        replaceTable(table, with: model, row: row, column: column)
    }
    @objc func tableMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        editTable(action)
    }

    /// Spreadsheet cells fill from the current cell, expanding only as needed.
    func pasteTableCells(_ text: String) -> Bool {
        guard text.contains("\t"), let table = currentTable else { return false }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines).components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        guard let width = rows.first?.count, rows.allSatisfy({ $0.count == width }),
              table.current.column + width <= DocumentTable.maximumColumns,
              table.current.row + rows.count <= DocumentTable.maximumRows else { return false }
        var model = table.model(in: attributedString())
        let columns = max(table.columns, table.current.column + width)
        for index in model.cells.indices { model.cells[index] += Array(repeating: "", count: columns - table.columns) }
        while model.cells.count < table.current.row + rows.count { model.cells.append(Array(repeating: "", count: columns)) }
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { model.cells[table.current.row + row][table.current.column + column] = value.replacingOccurrences(of: "|", with: "\\|") }
        }
        replaceTable(table, with: model, row: table.current.row, column: table.current.column)
        return true
    }

    func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        insertImages(panel.urls)
    }
    func insertImages(_ urls: [URL]) {
        do {
            let references = try urls.map { url -> (String, String) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (try assets.importImage(at: url, documentID: documentID), url.deletingPathExtension().lastPathComponent)
            }
            insertImageReferences(references)
        } catch { Toast.show("Couldn’t add this image. Choose a supported image under 50 MB.", systemImage: "exclamationmark.circle") }
    }
    func insertImageData(_ data: Data) {
        do { insertImageReferences([(try assets.importImage(data: data, documentID: documentID), "Image")]) }
        catch { Toast.show("Couldn’t add this image. Choose a supported image under 50 MB.", systemImage: "exclamationmark.circle") }
    }
    private func insertImageReferences(_ references: [(String, String)]) {
        guard !references.isEmpty else { return }
        let range = selectedRange()
        let inTable = currentTable != nil
        let separator = inTable ? "\u{2028}" : "\n"
        let content = NSMutableAttributedString()
        var attrs = inTable ? typingAttributes : baseAttributes()
        attrs.removeValue(forKey: .attachment)
        attrs.removeValue(forKey: .link)
        if range.location > 0, (string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) != "\n" {
            content.append(NSAttributedString(string: separator, attributes: attrs))
        }
        for (target, title) in references {
            let alt = title.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
            let image = MarkdownRich.parseInline("![\(alt)](\(target))", assets: assets)
            image.addAttributes(attrs, range: NSRange(location: 0, length: image.length))
            content.append(image)
            content.append(NSAttributedString(string: separator, attributes: attrs))
        }
        replace(range, with: content)
        setSelectedRange(NSRange(location: range.location + content.length, length: 0))
        typingAttributes = attrs
    }
    func image(at point: NSPoint) -> DocumentImageAttachment? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < attributedString().length,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return attributedString().attribute(.attachment, at: index, effectiveRange: nil) as? DocumentImageAttachment
    }
    func imageFiles(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
    }
    @objc func copyImageAction(_ sender: NSMenuItem) {
        guard let range = (sender.representedObject as? NSValue)?.rangeValue else { return }
        setSelectedRange(range); copy(nil)
    }
    @objc func removeImageAction(_ sender: NSMenuItem) {
        guard let range = (sender.representedObject as? NSValue)?.rangeValue else { return }
        replace(range, with: NSAttributedString(string: "", attributes: baseAttributes()))
        setSelectedRange(NSRange(location: range.location, length: 0))
    }
    @objc func imageMenuAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DocumentImagePreview.shared.open(url)
    }
}
