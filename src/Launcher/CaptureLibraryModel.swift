import AppKit
import SwiftUI
import GRDB
import ImageIO

enum CaptureLibraryMode: String, CaseIterable { case search = "Search", history = "History", themes = "Themes" }

@MainActor final class CaptureLibraryModel: ObservableObject {
    @Published var results: [CaptureMatch] = []
    @Published var themes: [CaptureTheme] = []
    @Published var selectedID: String?
    @Published var error: String?
    @Published var working = false
    @Published var hasMore = false
    @Published var matchingThemeIDs = Set<String>()
    @Published var queryHint: String?
    private let database: DatabaseQueue
    init(database: DatabaseQueue = Database.shared) { self.database = database }
    private var task: Task<Void, Never>?
    private var generation = 0
    private var limit = 60

    func reload(query: String, filter: CaptureFilter, more: Bool = false) {
        let database = self.database
        let resolved = CaptureQuery.resolve(query, filter: filter)
        let query = resolved.text, filter = resolved.filter
        queryHint = resolved.hint
        task?.cancel(); generation += 1
        let request = generation
        if more { limit += 60 } else { limit = 60 }
        let count = limit
        working = true; error = nil
        task = Task {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 55))
            guard !Task.isCancelled else { return }
            do {
                let first = try await Task.detached(priority: .userInitiated) {
                    let themes = try ThemeStore.list(database: database)
                    let matches: [CaptureMatch]
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        matches = try CaptureIndex.history(filter: filter, limit: count + 1, database: database).map {
                            CaptureMatch(item: $0, tier: 0, score: 0, excerpt: CaptureText.excerpt($0.body, query: ""), reason: $0.kind.capitalized, matchedTerms: [])
                        }
                    } else { matches = try CaptureIndex.lexical(query, filter: filter, limit: count, database: database) }
                    let themeIDs = try database.read { db in
                        try String.fetchAll(db, sql: "SELECT DISTINCT themeID FROM captureThemeMember WHERE blocked = 0 AND itemID IN (" + matches.map { _ in "?" }.joined(separator: ",") + ")", arguments: StatementArguments(matches.map(\.id)))
                    }
                    return (matches, themes, Set(themeIDs))
                }.value
                guard !Task.isCancelled, generation == request else { return }
                themes = first.1
                matchingThemeIDs = first.2
                hasMore = first.0.count > count
                results = Array(first.0.prefix(count))
                if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
                if !query.isEmpty {
                    let semantic = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
                    let worker = Task.detached(priority: .userInitiated) {
                        try CaptureIndex.expanded(query, filter: filter, lexical: first.0, limit: count, semantic: semantic, database: database)
                    }
                    let expanded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, generation == request else { return }
                    results = expanded
                    if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
                }
                working = false
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                self.error = "Couldn’t read your capture library. Try again."
                working = false
            }
        }
    }
    func cancel() { task?.cancel() }
    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : results.count)
        selectedID = results[min(max(0, index + delta), results.count - 1)].id
    }
    var selected: CaptureMatch? { results.first { $0.id == selectedID } }
}

enum CaptureThumbnailCache {
    static let cache = NSCache<NSString, NSImage>()
    static func clear() { cache.removeAllObjects() }
    static func load(path: String, size: Int = 100) -> NSImage? {
        let key = "\(path):\(OCRStore.version(URL(fileURLWithPath: path)) ?? ""):\(size)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.countLimit = 160
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor enum CaptureActions {
    private static let editor = EditorWindowController()
    static func open(_ item: CaptureItem, query: String = "") {
        guard let hit = try? Database.shared.read({ try item.hit(in: $0) }) else { return }
        SearchService.recordClick(query: query, hit: hit)
        switch hit {
        case .note(let note): NoteDocumentController.shared.open(note)
        case .meeting(let meeting):
            if query.isEmpty { MeetingDocumentController.shared.open(meetingID: meeting.id) }
            else { CaptureDetailController.shared.open(item, query: CaptureQuery.resolve(query, filter: CaptureFilter()).text) }
        case .screenshot(let shot):
            if !query.isEmpty { CaptureDetailController.shared.open(item, query: CaptureQuery.resolve(query, filter: CaptureFilter()).text) }
            else if let image = NSImage(contentsOfFile: shot.path) { editor.open(image: image, fileURL: URL(fileURLWithPath: shot.path)) }
            else { Toast.show("The original image is missing", systemImage: "exclamationmark.triangle") }
        case .recording(let recording): NSWorkspace.shared.open(URL(fileURLWithPath: recording.path))
        case .dictation: CaptureDetailController.shared.open(item, query: query)
        }
    }
    static func copy(_ item: CaptureItem, textOnly: Bool = false) {
        NSPasteboard.general.clearContents()
        if !textOnly, item.kind == "screenshot", let image = NSImage(contentsOfFile: item.sourcePath) { NSPasteboard.general.writeObjects([image]) }
        else if !textOnly, item.kind == "recording" { NSPasteboard.general.writeObjects([URL(fileURLWithPath: item.sourcePath) as NSURL]) }
        else { NSPasteboard.general.setString(item.body.isEmpty ? item.summary : item.body, forType: .string) }
    }
    static func confirmDelete(_ item: CaptureItem) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.title)”?"
        alert.informativeText = "Removes this capture, its OCR, transcript, index, themes, and current Brain export. Media moves to Trash. Existing Git history and backups may retain earlier exports."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { perform { try CaptureLifecycle.delete(item) } }
    }
    static func perform(_ action: () throws -> Void) {
        do { try action() } catch { Toast.show("Couldn’t update this capture. Please try again.", systemImage: "exclamationmark.triangle") }
    }
    static func prompt(title: String, value: String, action: (String) throws -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { perform { try action(field.stringValue) } }
    }
}
