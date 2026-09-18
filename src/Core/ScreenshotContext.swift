import AppKit
import ApplicationServices
import GRDB
import NaturalLanguage

/// Metadata belongs to an intentional capture, never a background activity log.
struct ScreenshotContext: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "captureContext"
    var itemID: String
    var timezone = ""
    var meetingID: String? = nil
    var app = ""
    var bundleID = ""
    var windowTitle = ""
    var url = ""
    var analysisJSON = "{}"
    var thumbnail: Data? = nil
    var imageVersion = ""

    var analysis: ScreenshotIntelligence.Analysis {
        (try? JSONDecoder().decode(ScreenshotIntelligence.Analysis.self, from: Data(analysisJSON.utf8))) ?? .init()
    }
    static func saveOrigin(_ origin: ScreenshotContext, in db: GRDB.Database, metadataEnabled: Bool = true, excludedApps: String = "") throws {
        guard let item = try CaptureItem.fetchOne(db, key: origin.itemID), !item.excluded else { return }
        var current = try fetchOne(db, key: origin.itemID) ?? origin
        current.timezone = origin.timezone
        current.meetingID = try origin.meetingID.flatMap { try Meeting.fetchOne(db, key: $0)?.id }
        let exclusions = Set(excludedApps.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let include = metadataEnabled && !exclusions.contains(origin.app.lowercased()) && !exclusions.contains(origin.bundleID.lowercased())
        current.app = include ? origin.app : ""; current.bundleID = include ? origin.bundleID : ""
        current.windowTitle = include ? origin.windowTitle : ""; current.url = include ? origin.url : ""
        try current.save(db)
        if item.generatedTitle.isEmpty, item.rawTitle.isEmpty, item.userTitle.isEmpty, ScreenshotIntelligence.usefulTitle(current.windowTitle) {
            try db.execute(sql: "UPDATE captureItem SET generatedTitle=? WHERE id=?", arguments: [current.windowTitle, item.id])
            try db.execute(sql: "INSERT OR IGNORE INTO capturePending(id) VALUES(?)", arguments: [item.id])
        }
    }
    static func clearWindowDetails(excludedApps: String? = nil, in db: GRDB.Database) throws {
        let excluded = excludedApps.map { Set($0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        for row in try Row.fetchAll(db, sql: "SELECT itemID,app,bundleID,windowTitle FROM captureContext") {
            let id: String = row["itemID"], app: String = row["app"], bundle: String = row["bundleID"], title: String = row["windowTitle"]
            guard excluded == nil || excluded!.contains(app.lowercased()) || excluded!.contains(bundle.lowercased()) else { continue }
            try db.execute(sql: "UPDATE captureItem SET generatedTitle='' WHERE id=? AND generatedTitle=? AND generatedTitle!=''", arguments: [id, title])
            try db.execute(sql: "UPDATE captureContext SET app='',bundleID='',windowTitle='',url='' WHERE itemID=?", arguments: [id])
            try db.execute(sql: "INSERT OR IGNORE INTO capturePending(id) SELECT id FROM captureItem WHERE id=? AND excluded=0", arguments: [id])
        }
    }
    struct Prepared { var analysisJSON: String; var thumbnail: Data?; var title: String }
    static func prepare(image: NSImage, lines: [ImageAnalysis.TextObservation], text: String) throws -> Prepared {
        let analysis = ScreenshotIntelligence.analyze(text: text, lines: lines, image: image)
        return Prepared(analysisJSON: String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self), thumbnail: ScreenshotIntelligence.thumbnail(image), title: ScreenshotIntelligence.title(text: text, lines: lines))
    }
    static func saveAnalysis(_ prepared: Prepared, itemID: String, version: String, in db: GRDB.Database) throws {
        guard let item = try CaptureItem.fetchOne(db, key: itemID), !item.excluded else { return }
        var context = try fetchOne(db, key: itemID) ?? ScreenshotContext(itemID: itemID)
        context.analysisJSON = prepared.analysisJSON; context.thumbnail = prepared.thumbnail; context.imageVersion = version
        try context.save(db)
        let title = prepared.title.isEmpty ? ScreenshotIntelligence.title(text: "", window: context.windowTitle) : prepared.title
        if item.rawTitle.isEmpty, item.userTitle.isEmpty {
            try db.execute(sql: "UPDATE captureItem SET generatedTitle=? WHERE id=?", arguments: [title, itemID])
            if title != item.generatedTitle { try db.execute(sql: "INSERT OR IGNORE INTO capturePending(id) VALUES(?)", arguments: [itemID]) }
        }
    }
}

enum ScreenshotIntelligence {
    /// Recording overlap is not evidence that a slide was shared. A repeated,
    /// distinctive company header that differs from the invite's company is
    /// a conservative off-topic hint; ordinary headings are not company names.
    static func offTopicForMeeting(text: String, domains: Set<String>) -> Bool {
        let companies = domains.compactMap { $0.split(separator: ".").first.map(String.init) }
        guard !companies.isEmpty else { return false }
        let words = MeetingSource.words(text)
        guard !companies.contains(where: { words.contains($0) }) else { return false }
        let header = text.components(separatedBy: .newlines).prefix(10)
        guard let dictionary = NLEmbedding.wordEmbedding(for: .english) else { return false }
        for line in header {
            let token = line.trimmingCharacters(in: .whitespaces)
            guard token.range(of: #"^[A-Z][a-z]{5,24}$"#, options: .regularExpression) != nil,
                  dictionary.vector(for: token.lowercased()) == nil,
                  text.lowercased().components(separatedBy: token.lowercased()).count >= 3 else { continue }
            return true
        }
        return false
    }
    struct Tag: Codable, Equatable { var name: String; var confidence: Double }
    struct Analysis: Codable {
        var summary = ""
        var tags: [Tag] = []
        var contains_pii = "unknown"
        var contains_confidential = "unknown"
        var perceptualHash = ""
    }
    static func usefulTitle(_ text: String) -> Bool {
        let words = CaptureText.words(text)
        guard (1...12).contains(words.count), text.count >= 5, text.count <= 110 else { return false }
        let normalized = words.joined(separator: " ")
        if normalized.range(of: #"^(?:q |o )?(?:search|sign in|sign out|log in|inbox|file edit|https|http|www)\b"#, options: .regularExpression) != nil { return false }
        return !["home", "settings", "help", "menu", "cancel", "google chrome", "safari", "microsoft edge"].contains(normalized)
            && text.range(of: #"@|\b\d{1,2}:\d{2}\b"#, options: .regularExpression) == nil
    }
    static func title(text: String, lines: [ImageAnalysis.TextObservation] = [], window: String = "") -> String {
        let candidates = lines.filter { usefulTitle($0.text) }
        // Vision exposes line geometry, not font weight. Prefer prominent text
        // outside the far-left navigation column; never claim to detect bold.
        if let best = candidates.max(by: {
            ($0.box.height * 8 + min($0.box.width, 0.7) * 0.15 + ($0.box.minX > 0.12 ? 0.08 : 0))
                < ($1.box.height * 8 + min($1.box.width, 0.7) * 0.15 + ($1.box.minX > 0.12 ? 0.08 : 0))
        }) { return String(best.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
        if usefulTitle(window) { return String(window.prefix(100)) }
        return text.components(separatedBy: .newlines).first(where: usefulTitle) ?? ""
    }
    static func analyze(text: String, lines: [ImageAnalysis.TextObservation], image: NSImage) -> Analysis {
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        var result = Analysis()
        if has(#"\bslide \d+ (?:of|/) \d+|\bsection\s+\d+\.\d+|\bboard (?:deck|presentation|materials)\b"#) { result.tags.append(.init(name: "slide-deck", confidence: 0.8)) }
        if has(#"\binbox\b|\bto me\b|\bsubject:\s|\bunread\b.*\bsent\b"#) { result.tags.append(.init(name: "email", confidence: 0.85)) }
        if has(#"\b(?:function|const|import|class|func)\s+\w+.*[({=]|\b(?:swift|typescript|javascript)\b"#) { result.tags.append(.init(name: "code", confidence: 0.7)) }
        if has(#"\b(?:dashboard|sign out|repair order|job board|checkout|subscription settings)\b"#) { result.tags.append(.init(name: "web-app", confidence: 0.7)) }
        if result.tags.isEmpty, text.split(whereSeparator: \.isWhitespace).count >= 60 { result.tags.append(.init(name: "document", confidence: 0.55)) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let phones = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
            let phone = phones?.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { ($0.phoneNumber ?? "").filter(\.isNumber).count >= 10 } ?? false
            result.contains_pii = has(#"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#) || phone ? "likely" : "not_detected"
            result.contains_confidential = has(#"\bconfidential\b|\binternal\b|\bboard (?:deck|meeting|of directors|materials|presentation)\b"#) ? "likely" : "not_detected"
        }
        let label = title(text: text, lines: lines)
        if !label.isEmpty {
            let kind = result.tags.max { $0.confidence < $1.confidence }?.name.replacingOccurrences(of: "-", with: " ") ?? "screenshot"
            result.summary = "\(kind.capitalized) showing \(label)."
        }
        result.perceptualHash = differenceHash(image) ?? ""
        return result
    }
    static func thumbnail(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 400 / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
    static func differenceHash(_ image: NSImage) -> String? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high; ctx.draw(source, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { hash = (hash << 1) | (bytes[y * 9 + x] > bytes[y * 9 + x + 1] ? 1 : 0) } }
        return String(format: "%016llx", hash)
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        guard a.count == 16, b.count == 16, let x = UInt64(a, radix: 16), let y = UInt64(b, radix: 16) else { return false }
        guard (4...60).contains(x.nonzeroBitCount), (4...60).contains(y.nonzeroBitCount) else { return false }
        return (x ^ y).nonzeroBitCount <= 4
    }
}

/// Capture the window list once with the frozen screen. Resolve the selected
/// region afterward; foreground context is never attached to another window.
struct CaptureWindowSnapshot: @unchecked Sendable {
    struct Window { var bounds: CGRect; var app: String; var bundleID: String; var title: String; var url: String }
    var windows: [Window] = []
    static func take() -> CaptureWindowSnapshot {
        guard UserDefaults.standard.bool(forKey: "captureWindowMetadata") else { return .init() }
        let excluded = Set((UserDefaults.standard.string(forKey: "captureMetadataExcludedApps") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result = CaptureWindowSnapshot()
        var inspectedApps = Set<Int32>()
        for entry in entries {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let application = NSRunningApplication(processIdentifier: pid),
                  let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
            let app = application.localizedName ?? "", bundle = application.bundleIdentifier ?? ""
            // Keep excluded windows as occluders, with no metadata attached.
            let allowed = application.bundleIdentifier != Bundle.main.bundleIdentifier && !excluded.contains(app.lowercased()) && !excluded.contains(bundle.lowercased())
            let title = allowed ? entry[kCGWindowName as String] as? String ?? "" : ""
            var url = ""
            if allowed, application.isActive, inspectedApps.insert(pid).inserted, AXIsProcessTrusted() {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.15)
                var focused: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                    let window = unsafeBitCast(focused, to: AXUIElement.self)
                    var document: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success, let value = document as? String,
                       var components = URLComponents(string: value), ["https", "http"].contains(components.scheme) {
                        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
                        url = components.string ?? ""
                    }
                }
            }
            result.windows.append(Window(bounds: bounds, app: allowed ? app : "", bundleID: allowed ? bundle : "", title: title, url: url))
        }
        return result
    }
    func selected(in rect: CGRect, mainDisplayHeight: CGFloat) -> Window? {
        let point = CGPoint(x: rect.midX, y: mainDisplayHeight - rect.midY)
        let quartz = CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
        guard let window = windows.first(where: { $0.bounds.contains(point) }), !window.app.isEmpty,
              window.bounds.intersection(quartz).width * window.bounds.intersection(quartz).height >= rect.width * rect.height * 0.6 else { return nil }
        return window
    }
}
