import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Images belong to the document that imported them. Relative Markdown links
/// keep a Brain export portable, and deleting a source screenshot is harmless.
struct DocumentAssets {
    var root: URL = Brain.root.appendingPathComponent("assets", isDirectory: true)
    static let shared = DocumentAssets()
    static let imagePattern = #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#

    private func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
            && value != "." && value != ".."
    }
    func resolve(_ target: String) -> URL? {
        guard target.hasPrefix("../assets/") else { return nil }
        let parts = target.dropFirst("../assets/".count).split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy(validComponent) else { return nil }
        let url = root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return nil }
        return url
    }
    func importImage(at url: URL, documentID: String) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try importImage(data: Data(contentsOf: url, options: .mappedIfSafe), documentID: documentID)
    }
    func importImage(data: Data, documentID: String) throws -> String {
        guard validComponent(documentID), data.count <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000
        else { throw CocoaError(.fileReadCorruptFile) }
        let folder = root.appendingPathComponent(documentID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let filename = UUID().uuidString + "." + ext
        try data.write(to: folder.appendingPathComponent(filename), options: .atomic)
        return "../assets/\(documentID)/\(filename)"
    }
    func ownedFiles(documentID: String) -> [URL] {
        guard validComponent(documentID) else { return [] }
        let folder = root.appendingPathComponent(documentID)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { resolve("../assets/\(documentID)/\($0.lastPathComponent)") != nil }
    }
    /// A pasted image gets its own copy in the destination document, so either
    /// document can be deleted independently. Same-document undo shares bytes.
    func adoptingImages(in markdown: String, documentID: String) throws -> String {
        let regex = try NSRegularExpression(pattern: Self.imagePattern)
        let ns = markdown as NSString
        var result = markdown
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let target = ns.substring(with: match.range(at: 2))
            guard !target.hasPrefix("../assets/\(documentID)/"), let url = resolve(target) else { continue }
            let copied = try importImage(at: url, documentID: documentID)
            result = (result as NSString).replacingCharacters(in: match.range(at: 2), with: copied)
        }
        return result
    }
    static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class DocumentImageAttachment: NSTextAttachment {
    let markdown: String
    let sourceURL: URL
    let alternativeText: String
    init(markdown: String, url: URL, alternativeText: String) {
        self.markdown = markdown; self.sourceURL = url; self.alternativeText = alternativeText
        super.init(data: nil, ofType: nil)
        image = DocumentAssets.thumbnail(url) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: alternativeText)
        bounds = fittedBounds(width: MM.Document.columnWidth)
    }
    required init?(coder: NSCoder) { nil }
    private func fittedBounds(width: CGFloat) -> CGRect {
        let size = image?.size ?? NSSize(width: 240, height: 160)
        let scale = min(1, max(40, width) / max(1, size.width), 480 / max(1, size.height))
        return CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        fittedBounds(width: min(MM.Document.columnWidth, lineFrag.width - 10))
    }
}

@MainActor final class DocumentImagePreview {
    static let shared = DocumentImagePreview()
    private var window: ImagePreviewWindow?
    func open(_ url: URL, fullScreen: Bool = true) {
        guard let image = NSImage(contentsOf: url) else { return }
        window?.close()
        let preview = ImagePreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        preview.title = "Image preview"
        preview.representedURL = url
        preview.titlebarAppearsTransparent = true
        preview.titleVisibility = .hidden
        preview.collectionBehavior = [.fullScreenPrimary]
        preview.contentView = NSHostingView(rootView: ImagePreviewContent(image: image) { [weak preview] in preview?.close() })
        preview.center(); window = preview
        preview.makeKeyAndOrderFront(nil)
        if fullScreen { preview.toggleFullScreen(nil) }
    }
    func close() { window?.close(); window = nil }
}

final class ImagePreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

struct ImagePreviewContent: View {
    let image: NSImage
    var close: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            MM.Colors.background.ignoresSafeArea()
            ZoomableDocumentImage(image: image).padding(MM.Document.margin)
            Button(action: close) { IconView(icon: .close, size: 22).clickable(minSize: 36) }
                .buttonStyle(.plain).padding(MM.Layout.padding).help("Close image (Esc)").accessibilityLabel("Close image")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ZoomableDocumentImage: NSViewRepresentable {
    let image: NSImage
    final class Scroll: NSScrollView {
        override func layout() {
            super.layout()
            guard let view = documentView as? NSImageView, magnification == 1 else { return }
            if view.frame.size != contentSize { view.setFrameSize(contentSize) }
        }
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Scroll()
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1; scroll.maxMagnification = 6
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        view.setAccessibilityLabel("Full resolution image. Pinch to zoom; Escape to close.")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { (nsView.documentView as? NSImageView)?.image = image }
}
