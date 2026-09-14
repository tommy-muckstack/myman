import AppKit

/// Temporary rendered previews are never indexed. Expire them after an hour,
/// on capture deletion/exclusion, or when the app next starts. Final files stay
/// under the existing capture library's lifecycle.
@MainActor final class AgentMediaStore {
    static let shared = AgentMediaStore()
    let root: URL
    private var observer: NSObjectProtocol?
    private var exclusionObserver: NSObjectProtocol?
    private var timer: Timer?
    init(root: URL? = nil) {
        self.root = root ?? (VerificationPaths.root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.muckstack.myman"))
            .appendingPathComponent("AgentMedia", isDirectory: true)
        purge()
        observer = NotificationCenter.default.addObserver(forName: .captureDeleted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        exclusionObserver = NotificationCenter.default.addObserver(forName: .captureExcluded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }
    deinit { if let exclusionObserver { NotificationCenter.default.removeObserver(exclusionObserver) }; if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    func purge() { try? FileManager.default.removeItem(at: root) }
    func expire() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(date) >= 3600 { try? FileManager.default.removeItem(at: file) }
        }
    }
    func image(_ image: NSImage, prefix: String = "preview") throws -> [String: Any] {
        expire()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard entries.count < 256 else { throw AgentError("PREVIEW_LIMIT", "Too many temporary previews; let older previews expire before generating more.") }
        let url = root.appendingPathComponent(prefix + "-" + UUID().uuidString + ".png")
        let data = try AgentImages.png(image)
        guard data.count <= 32 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Preview exceeds 32 MiB; reduce its dimensions.") }
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ["path": url.path, "mime_type": "image/png", "width": AgentImages.size(image).width, "height": AgentImages.size(image).height,
                "file_size": data.count, "duration": NSNull(), "preview_path": url.path, "expires_at": AgentActions.date(Date().addingTimeInterval(3600))]
    }
    func document(_ data: Data) throws -> [String: Any] {
        expire()
        guard data.count <= 32 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Share page exceeds 32 MiB. Choose fewer images or a shorter video export.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 256 else { throw AgentError("PREVIEW_LIMIT", "Let older previews expire before exporting more.") }
        let url = root.appendingPathComponent("brief-share-" + UUID().uuidString + ".html")
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ["path": url.path, "mime_type": "text/html", "file_size": data.count, "expires_at": AgentActions.date(Date().addingTimeInterval(3600))]
    }
    func file(_ data: Data, extension suffix: String, mime: String, maximum: Int) throws -> [String: Any] {
        expire()
        guard data.count <= maximum, ["md", "png", "mov", "mp4", "m4v"].contains(suffix.lowercased()) else { throw AgentError("TOO_LARGE", "Unsupported or oversized handoff attachment.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 256 else { throw AgentError("PREVIEW_LIMIT", "Let older handoffs expire before exporting more.") }
        let url = root.appendingPathComponent("context-" + UUID().uuidString + "." + suffix)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ["path": url.path, "mime_type": mime, "file_size": data.count, "expires_at": AgentActions.date(Date().addingTimeInterval(3600))]
    }
    static func canvas(size: CGSize, draw: (CGContext) -> Void) throws -> NSImage {
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 32_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentError("INVALID_IMAGE", "Rendered image exceeds supported dimensions.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = context.makeImage() else { throw AgentError("INVALID_IMAGE", "Could not render preview.") }
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
    }
    static func thumbnail(_ image: NSImage, maximum: CGFloat = 512) throws -> NSImage {
        let size = AgentImages.size(image), scale = min(1, maximum / max(size.width, size.height))
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        return try canvas(size: target) { context in
            context.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
    static func imageAttachment(_ image: NSImage, path: String) -> [String: Any] {
        let dimensions = AgentImages.size(image)
        var result: [String: Any] = ["path": path, "mime_type": "image/png", "width": dimensions.width, "height": dimensions.height,
                                     "file_size": ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0,
                                     "duration": NSNull(), "preview_path": NSNull()]
        do {
            let preview = try shared.image(thumbnail(image), prefix: "thumbnail")
            result["preview_path"] = preview["path"]; result["preview_expires_at"] = preview["expires_at"]
        } catch { result["preview_status"] = "unavailable" }
        return result
    }
}
