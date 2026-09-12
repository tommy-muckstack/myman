import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO
import SwiftUI
import GRDB

@MainActor
final class FontWorkbenchController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static var windows: [UUID: FontWorkbenchController] = [:]
    private let id = UUID()
    let window: NSWindow
    let webView: WKWebView
    let assets = FontWorkbenchAssets()
    private let recognition = FontRecognition()
    private var sources: [[String: Any]] = []
    private var imageData: [Data] = []
    private var restored: [String: Any]?
    private var savedURL: URL?
    private var closed = false
    private var generation = 0
    private var sourceTitle = "Screenshot"
    private var deletedObserver: NSObjectProtocol?
    private var sourceItemID: String?
    var ready = false
    var startupError: String?

    static func open(image: NSImage, sourceURL: URL) {
        do {
            let controller = FontWorkbenchController()
            controller.sourceTitle = sourceURL.deletingPathExtension().lastPathComponent
            controller.sourceItemID = try Database.shared.read { try String.fetchOne($0, sql: "SELECT id FROM captureItem WHERE sourcePath = ?", arguments: [sourceURL.path]) }
            try controller.add(data: AgentImages.png(image), title: controller.sourceTitle)
            controller.show()
        } catch { Toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
    }
    static func openProject(noteID: String) throws {
        let project = try FontProjectStore.load(noteID)
        guard let state = project["state"] as? [String: Any], let refs = project["images"] as? [String], refs.count <= 3 else { throw AgentError("INVALID_PROJECT", "Invalid font project.") }
        let controller = FontWorkbenchController(); controller.restored = state; controller.sourceItemID = "note-" + noteID
        for ref in refs {
            guard ref.hasPrefix("../assets/note-\(noteID)/"), let url = DocumentAssets.shared.resolve(ref) else { throw AgentError("INVALID_PROJECT", "Invalid source image reference.") }
            try controller.add(data: AgentImages.png(AgentImages.load(url)), title: "Font sample")
        }
        controller.savedURL = FontProjectStore.asset(noteID, "font.otf"); controller.show()
    }
    static func generateForAgent(image: NSImage, title: String, sourceID: String, name: String, capturedOnly: Bool) async throws -> [String: Any] {
        let result = try await analyzeForAgent(image: image, title: title, sourceID: sourceID, name: name, capturedOnly: capturedOnly)
        let matches = result["candidates"] as? [[String: Any]] ?? []
        let (note, _) = try FontProjectStore.save(font: Data(base64Encoded: result["font"] as! String)!, name: name, state: result["project"] as! [String: Any], provenance: result["provenance"] as! [[String: Any]], images: [try AgentImages.png(image)], sourceTitle: title, matches: matches)
        return try AgentFonts.file(noteID: note.id)
    }
    static func matchForAgent(image: NSImage, title: String, sourceID: String) async throws -> [String: Any] {
        let result = try await analyzeForAgent(image: image, title: title, sourceID: sourceID, name: "Lettering specimen", capturedOnly: true)
        let data = Data(base64Encoded: result["font"] as! String)!
        return ["source_id": sourceID, "candidates": result["candidates"] ?? [], "catalog_size": result["catalog_size"] ?? 0,
                "scope": "bundled_styles", "exact_identity_verified": false, "score_type": "distance_lower_is_better",
                "captured_characters": result["captured"] ?? [], "preview": try AgentFonts.specimen(data: data, text: (result["captured"] as? [String] ?? []).joined(separator: " ")),
                "limitations": "Closest bundled styles only; screenshot shape similarity does not establish the original font family."]
    }
    private static func analyzeForAgent(image: NSImage, title: String, sourceID: String, name: String, capturedOnly: Bool) async throws -> [String: Any] {
        let controller = FontWorkbenchController(); controller.sourceTitle = title; controller.sourceItemID = sourceID
        try controller.add(data: AgentImages.png(image), title: title); controller.show()
        defer { controller.window.close() }
        let deadline = Date().addingTimeInterval(30)
        while !controller.ready, !controller.closed, controller.startupError == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard controller.ready, !controller.closed else { throw AgentError("FONT_UNAVAILABLE", controller.startupError ?? "Font window did not open.") }
        _ = try await controller.webView.callAsyncJavaScript("document.getElementById('name').value=name; await window.fontWorkbench.run(capturedOnly);", arguments: ["name": name, "capturedOnly": capturedOnly], in: nil, contentWorld: .page)
        guard !controller.closed else { throw CancellationError() }
        let value = try await controller.webView.callAsyncJavaScript("const result=window.fontWorkbench.inspect(); if(!result.ready) throw Error(document.getElementById('status').textContent); return {...result, ...await window.fontWorkbench.exportProject()};", arguments: [:], in: nil, contentWorld: .page)
        guard let result = value as? [String: Any], let encoded = result["font"] as? String, let font = Data(base64Encoded: encoded), let state = result["project"] as? [String: Any], result["provenance"] is [[String: Any]] else { throw AgentError("FONT_FAILED", "No valid font generated.") }
        guard !controller.closed, let source = CaptureIndex.item(sourceID), !source.excluded else { throw AgentError("NOT_FOUND", "The source screenshot was deleted or excluded.") }
        try FontProjectStore.validate(font)
        try FontProjectStore.validateState(state)
        return result
    }
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(assets, forURLScheme: "myman-font")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 820), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Create font"; window.minSize = NSSize(width: 720, height: 540)
        window.isReleasedWhenClosed = false; window.delegate = self; window.contentView = webView
        webView.autoresizingMask = [.width, .height]; webView.navigationDelegate = self
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "font")
        // Native rule protects all remote subresources as well as navigation.
        // Scheme assets are a fixed bundle allowlist plus selected image bytes.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MyManFontOffline", encodedContentRuleList: rules) { [weak self] rule, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard let rule, error == nil else { self.window.close(); return }
                self.webView.configuration.userContentController.add(rule)
                self.webView.load(URLRequest(url: URL(string: "myman-font://bundle/index.html")!))
            }
        }
        deletedObserver = NotificationCenter.default.addObserver(forName: .captureDeleted, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { guard let self, notification.object as? String == self.sourceItemID else { return }; self.window.close() }
        }
    }
    func add(data: Data, title: String) throws {
        guard sources.count < 3, data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 32_000_000 else { throw AgentError("INVALID_IMAGE", "Use up to three screenshots, each under 32 megapixels.") }
        let id = UUID().uuidString, path = "/source/" + id + ".png"
        assets.put(data, at: path)
        imageData.append(data)
        sources.append(["id": id, "title": title, "url": "myman-font://bundle" + path, "width": width, "height": height])
    }
    private func show() { Self.windows[id] = self; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        func css(_ color: Color) -> String {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .labelColor
            return "rgba(\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255)),\(c.alphaComponent))"
        }
        var payload: [String: Any] = ["images": sources, "palette": ["background": css(MM.Colors.background), "surface": css(MM.Colors.surface), "text": css(MM.Colors.textPrimary), "secondary": css(MM.Colors.textSecondary), "border": css(MM.Colors.border), "accent": css(MM.Colors.accent)]]
        if let restored { payload["project"] = restored }
        Task { @MainActor in
            do { _ = try await webView.callAsyncJavaScript("await window.fontWorkbench.start(payload)", arguments: ["payload": payload], in: nil, contentWorld: .page); ready = true }
            catch { startupError = String(describing: error) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { startupError = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { startupError = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.scheme == "myman-font" && url?.host == "bundle" && url?.path == "/index.html" ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard !closed, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "myman-font", message.frameInfo.securityOrigin.host == "bundle",
              let payload = message.body as? [String: Any], let action = payload["action"] as? String else { replyHandler(nil, "Invalid font request."); return }
        Task { @MainActor in
            do {
                let value = try await perform(action, payload)
                guard !closed else { replyHandler(nil, "Window closed."); return }
                replyHandler(value, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }
    private func perform(_ action: String, _ payload: [String: Any]) async throws -> Any {
        switch action {
        case "fontAsset":
            guard let path = payload["path"] as? String, path.hasPrefix("/fonts/"), let url = URL(string: "myman-font://bundle" + path), let (data, _) = assets.resource(url), data.count <= 4 * 1024 * 1024 else { throw AgentError("INVALID_ASSET", "Unknown bundled font asset.") }
            return data.base64EncodedString()
        case "recognize":
            generation += 1; let run = generation
            guard let text = payload["png"] as? String, text.count <= 34 * 1024 * 1024, let data = Data(base64Encoded: text) else { throw AgentError("INVALID_IMAGE", "Invalid text image.") }
            let result = try await recognition.recognize(data)
            guard !closed, run == generation else { throw CancellationError() }; return result
        case "cancel": generation += 1; recognition.cancel(); return true
        case "addImages":
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = true
            guard await panel.beginSheetModal(for: window) == .OK, !closed else { return [] }
            let start = sources.count
            guard panel.urls.count <= 3 - start else { throw AgentError("TOO_MANY_IMAGES", "Use no more than three screenshots.") }
            for url in panel.urls { try add(data: AgentImages.png(AgentImages.load(url)), title: url.lastPathComponent) }
            return Array(sources.dropFirst(start))
        case "original":
            guard let name = payload["name"] as? String else { return false }
            let families = ["Inter", "Poppins", "Noto Serif", "Lato", "Montserrat", "Open Sans", "Playfair Display", "Oswald", "Raleway", "Roboto Slab"]
            guard let family = families.first(where: { name == $0 || name.hasPrefix($0 + " ") }), let url = URL(string: "https://fonts.google.com/specimen/" + family.replacingOccurrences(of: " ", with: "+")) else { throw AgentError("INVALID_ARGUMENTS", "Unknown suggested font.") }
            NSWorkspace.shared.open(url); return true
        case "save":
            guard let raw = payload["font"] as? String, raw.count <= 24 * 1024 * 1024, let font = Data(base64Encoded: raw),
                  let state = payload["project"] as? [String: Any], let provenance = payload["provenance"] as? [[String: Any]], provenance.count <= 95,
                  let name = payload["name"] as? String, name.count <= 64 else { throw AgentError("INVALID_FONT", "Invalid font export.") }
            try FontProjectStore.validate(font)
            let run = generation
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "otf")!]
            panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".otf"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return ["saved": false] }
            guard !closed, run == generation else { throw CancellationError() }
            try font.write(to: url, options: .atomic)
            let (_, managedURL) = try FontProjectStore.save(font: font, name: name, state: state, provenance: provenance, images: imageData, sourceTitle: sourceTitle)
            savedURL = managedURL
            return ["saved": true, "path": url.path]
        case "openSaved": guard let savedURL else { return false }; NSWorkspace.shared.open(savedURL); return true
        default: throw AgentError("UNKNOWN_ACTION", "Unknown font action.")
        }
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; generation += 1; recognition.cancel(); webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "font", contentWorld: .page)
        webView.navigationDelegate = nil; assets.clear(); imageData = []; sources = []; restored = nil
        if let deletedObserver { NotificationCenter.default.removeObserver(deletedObserver) }
        Self.windows[id] = nil
    }
}

/// Bundle-only resources and explicitly selected images. The URL path never
/// becomes an unchecked filesystem path, and no remote URL is proxied.
final class FontWorkbenchAssets: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: Data] = [:]
    private let files: [String: URL]
    override init() {
        var files: [String: URL] = [:]
        if let root = Bundle.module.url(forResource: "FontWorkbench", withExtension: nil)?.resolvingSymlinksInPath(),
           let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in iterator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") { files[String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))] = url }
            }
        }
        for name in ["Gellix-Regular.ttf", "Gellix-Medium.ttf"] {
            files["/ui/" + name] = Bundle.module.url(forResource: "Fonts", withExtension: nil)?.appendingPathComponent(name)
        }
        self.files = files; super.init()
    }
    func put(_ data: Data, at path: String) { lock.lock(); images[path] = data; lock.unlock() }
    func clear() { lock.lock(); images.removeAll(); lock.unlock() }
    func resource(_ url: URL) -> (Data, String)? {
        guard url.scheme == "myman-font", url.host == "bundle", url.query == nil, url.fragment == nil else { return nil }
        lock.lock(); let image = images[url.path]; lock.unlock()
        if let image { return (image, "image/png") }
        guard let file = files[url.path], let data = try? Data(contentsOf: file) else { return nil }
        let mime = ["html": "text/html", "js": "application/javascript", "css": "text/css", "ttf": "font/ttf", "txt": "text/plain"][file.pathExtension] ?? "application/octet-stream"
        return (data, mime)
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let (data, mime) = resource(url) else { urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission)); return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
