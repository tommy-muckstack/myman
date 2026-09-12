import AppKit
import SwiftUI
import GRDB

@MainActor final class CaptureDetailController {
    static let shared = CaptureDetailController()
    private var windows: [String: NSWindow] = [:]
    private var deletionObserver: NSObjectProtocol?
    private init() {
        deletionObserver = NotificationCenter.default.addObserver(forName: .captureDeleted, object: nil, queue: .main) { [weak self] event in
            guard let id = event.object as? String else { return }
            MainActor.assumeIsolated { let window = self?.windows.removeValue(forKey: id); window?.contentView = nil; window?.close() }
        }
    }
    func open(_ item: CaptureItem, query: String = "") {
        let window = windows[item.id] ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = item.title
        window.contentView = NSHostingView(rootView: CaptureDetailView(item: item, query: query))
        if windows[item.id] == nil { window.center() }
        windows[item.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    static func openPath(_ path: String) {
        guard let item = try? Database.shared.read({ try CaptureItem.fetchOne($0, sql: "SELECT * FROM captureItem WHERE sourcePath = ?", arguments: [path]) }) else { return }
        shared.open(item)
    }
}

struct CaptureRelatedSection: View {
    let itemID: String
    var database: DatabaseQueue = Database.shared
    @State private var themes: [CaptureTheme] = []
    @State private var related: [CaptureRelationship] = []
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Related", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(themes) { theme in
                    Button { CaptureThemeWindow.shared.open(theme) } label: {
                        Label { Text("\(theme.title) · \(theme.count) items") } icon: { IconView(icon: .themes) }
                    }.buttonStyle(.plain).clickable().foregroundStyle(MM.Colors.accent)
                }
                ForEach(related) { relation in
                    Button { CaptureActions.open(relation.item) } label: {
                        HStack {
                            IconView(icon: relation.item.icon)
                            Text(relation.item.title).lineLimit(1)
                            Spacer()
                            Text(relation.reason).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).lineLimit(1)
                        }
                    }.buttonStyle(.plain).clickable()
                }
                if themes.isEmpty && related.isEmpty { UtilityEmptyState(icon: .related, title: "Connections take shape", message: "Related captures will show up here.", compact: true) }
            }.padding(.top, 8)
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
        .task(id: itemID) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in Task { await reload() } }
    }
    private func reload() async {
        let value = await Task.detached(priority: .utility) { (try? ThemeStore.list(itemID: itemID, database: database), try? RelatedItems.items(for: itemID, limit: 5, database: database)) }.value
        guard !Task.isCancelled else { return }
        themes = value.0 ?? []; related = value.1 ?? []
    }
}

@MainActor final class CaptureThemeWindow {
    static let shared = CaptureThemeWindow()
    private var window: NSWindow?
    func open(_ theme: CaptureTheme) {
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = theme.title
        window.contentView = NSHostingView(rootView: ThemeTimelineView(theme: theme))
        if self.window == nil { window.center() }
        self.window = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}

struct ThemeTimelineView: View {
    let theme: CaptureTheme
    @State private var items: [CaptureItem] = []
    @State private var limit = 60
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(theme.title).font(MM.Fonts.title)
            Text("\(theme.count) captures · Latest \(theme.latest.formatted(date: .abbreviated, time: .shortened))").font(MM.Fonts.secondary)
            Text(theme.typeCounts).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            ScrollView {
                LazyVStack {
                    ForEach(items) { item in
                        CaptureResultRow(match: CaptureMatch(item: item, tier: 0, score: 0, excerpt: CaptureText.excerpt(item.body, query: ""), reason: item.kind.capitalized, matchedTerms: []))
                            .clickable().onTapGesture { CaptureActions.open(item) }
                            .contextMenu {
                                Button("Preview & related") { CaptureDetailController.shared.open(item) }
                                Button("Remove from theme") { CaptureActions.perform { try ThemeStore.assign(item.id, to: theme.id, remove: true) } }
                            }
                    }
                    if items.isEmpty { UtilityEmptyState(icon: .themes, title: "A little room to grow", message: "Captures in this theme will appear here.").frame(minHeight: 300) }
                    if items.count == limit { Button("Show more") { limit += 60 }.clickable() }
                }
            }
        }.padding(MM.Layout.padding).background(MM.Colors.background).foregroundStyle(MM.Colors.textPrimary)
        .task(id: limit) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in Task { await reload() } }
    }
    private func reload() async {
        let count = limit
        items = (try? await Task.detached { try CaptureIndex.history(filter: CaptureFilter(themeID: theme.id), limit: count) }.value) ?? []
    }
}

struct OCRLocationOverlay: View {
    var lines: [ImageAnalysis.TextObservation]
    var query: String
    var selected: UUID?
    var body: some View {
        Canvas { context, size in
            let terms = CaptureText.words(query)
            for line in lines where line.id == selected || (!terms.isEmpty && terms.contains(where: { line.text.localizedCaseInsensitiveContains($0) })) {
                let rect = line.rect(in: size).insetBy(dx: -2, dy: -2)
                context.fill(Path(rect), with: .color(MM.Colors.accent.opacity(0.22)))
                context.stroke(Path(rect), with: .color(MM.Colors.accent), lineWidth: 1.5)
            }
        }.allowsHitTesting(false)
    }
}

struct CaptureDetailView: View {
    @State var item: CaptureItem
    @State var query: String
    var database: DatabaseQueue = Database.shared
    @State private var image: NSImage?
    @State private var lines: [ImageAnalysis.TextObservation] = []
    @State private var selected: UUID?
    @State private var objects: [String] = []
    @State private var paragraphs = false
    private var textRegions: [ImageAnalysis.TextObservation] { paragraphs ? OCRStore.paragraphs(lines) : lines }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.title).font(MM.Fonts.title).lineLimit(2)
                    Text("\(item.kind.capitalized) · \(item.capturedAt.formatted(date: .abbreviated, time: .shortened))").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer()
                if item.kind != "dictation" { Button("Open original") { CaptureActions.open(item) }.clickable() }
                Button(item.kind == "screenshot" ? "Copy all text" : "Copy text") { CaptureActions.copy(item, textOnly: true) }.clickable()
            }
            TextField(item.kind == "screenshot" ? "Find in screenshot text" : "Find in captured text", text: $query).textFieldStyle(.roundedBorder)
            if item.kind == "screenshot" {
                Toggle("Group nearby lines into paragraphs", isOn: $paragraphs).font(MM.Fonts.secondary)
            }
            HSplitView {
                if let image {
                    GeometryReader { geo in
                        let scale = min(geo.size.width / image.size.width, geo.size.height / image.size.height)
                        Image(nsImage: image).resizable().frame(width: image.size.width * scale, height: image.size.height * scale)
                            .overlay { OCRLocationOverlay(lines: textRegions, query: query, selected: selected) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(minWidth: 260)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if item.kind == "screenshot", !lines.isEmpty {
                            ForEach(textRegions.filter { line in query.isEmpty || CaptureText.words(query).contains(where: { line.text.localizedCaseInsensitiveContains($0) }) }) { line in
                                HStack(alignment: .top) {
                                    HighlightedCaptureText(text: line.text, terms: CaptureText.words(query)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        .onTapGesture { selected = line.id }
                                    Button { selected = line.id; copy(line.text) } label: { Image(systemName: "doc.on.doc").clickable() }.buttonStyle(.plain).help("Copy this text region")
                                }.padding(6).background(selected == line.id ? MM.Colors.surface : .clear)
                            }
                        } else {
                            if !query.isEmpty {
                                HighlightedCaptureText(text: CaptureText.excerpt(item.body, query: query, length: 400), terms: CaptureText.words(query))
                                    .padding(MM.Layout.spacing).background(MM.Colors.surface).textSelection(.enabled)
                            }
                            HighlightedCaptureText(text: item.body, terms: CaptureText.words(query)).textSelection(.enabled)
                            if !item.summary.isEmpty {
                                Text("Notes & summary").font(MM.Fonts.body)
                                HighlightedCaptureText(text: item.summary, terms: CaptureText.words(query)).textSelection(.enabled)
                            }
                        }
                        ForEach(objects, id: \.self) { object in
                            Menu(object) {
                                Button("Copy") { copy(object) }
                                if let url = URL(string: object), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                }
                            }.menuStyle(.borderlessButton).clickable()
                        }
                    }.font(MM.Fonts.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 230, idealWidth: 300)
                    .overlay {
                        if item.kind == "screenshot", lines.isEmpty, item.body.isEmpty {
                            UtilityEmptyState(icon: .screenshot, title: "A picture can be enough", message: "No readable text was found in this capture.", compact: true)
                        }
                    }
            }
            CaptureRelatedSection(itemID: item.id, database: database)
        }.padding(MM.Layout.paddingLarge).background(MM.Colors.background).foregroundStyle(MM.Colors.textPrimary)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in Task { await reload() } }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func reload() async {
        let id = item.id
        let value = await Task.detached(priority: .utility) { () -> (CaptureItem?, NSImage?, [ImageAnalysis.TextObservation], [String]) in
            guard let fresh = CaptureIndex.item(id, database: database) else { return (nil, nil, [], []) }
            let image = fresh.kind == "screenshot" ? CaptureThumbnailCache.load(path: fresh.sourcePath, size: 1600) : nil
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue | NSTextCheckingResult.CheckingType.date.rawValue)
            let text = String(fresh.body.prefix(30000))
            let objects = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                if let url = match.url { return url.absoluteString }
                return Range(match.range, in: text).map { String(text[$0]) }
            } ?? []
            return (fresh, image, fresh.kind == "screenshot" ? OCRStore.lines(itemID: id, database: database) : [], Array(Set(objects)).sorted())
        }.value
        guard !Task.isCancelled, let fresh = value.0 else { return }
        item = fresh; image = value.1; lines = value.2; objects = value.3
    }
}
