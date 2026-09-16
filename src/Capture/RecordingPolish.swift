import AppKit
import Carbon.HIToolbox
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// "Polish recording": the visible 80% of CleanShot's Studio Mode, done as a
// single export rather than a timeline editor. A recording stays untouched;
// polishing writes a new .mp4 beside it with a backdrop, a trim, and smooth
// zooms toward wherever the user clicked.

/// A click during a recording, as fractions of the recorded area
/// (top-left origin) and seconds from the start of the recording.
struct RecordedClick: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

/// Clicks live in a sidecar next to the movie so polishing works later too.
enum ClickLog {
    static func url(for movie: URL) -> URL { movie.appendingPathExtension("clicks.json") }

    static func save(_ clicks: [RecordedClick], for movie: URL) {
        guard !clicks.isEmpty, let data = try? JSONEncoder().encode(clicks) else { return }
        try? data.write(to: url(for: movie), options: .atomic)
    }

    static func load(for movie: URL) -> [RecordedClick] {
        guard let data = try? Data(contentsOf: url(for: movie)),
              let clicks = try? JSONDecoder().decode([RecordedClick].self, from: data) else { return [] }
        return clicks.filter { $0.time.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }.sorted { $0.time < $1.time }
    }
}

/// Watches clicks inside the recorded region while a recording runs. Mouse
/// monitors need no Accessibility grant.
@MainActor
final class ClickRecorder {
    private(set) var clicks: [RecordedClick] = []
    private var monitors: [Any] = []
    private let region: CGRect
    private let startedAt: Date

    init(regionAppKit: CGRect, startedAt: Date) {
        self.region = regionAppKit
        self.startedAt = startedAt
        let record: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.record(location) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: record) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in record(event); return event }) { monitors.append(local) }
    }

    func record(_ location: CGPoint, at date: Date = Date()) {
        guard region.width > 0, region.height > 0, region.contains(location) else { return }
        clicks.append(RecordedClick(time: date.timeIntervalSince(startedAt),
                                    x: (location.x - region.minX) / region.width,
                                    y: 1 - (location.y - region.minY) / region.height))
    }

    func stop() -> [RecordedClick] {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        return clicks
    }
}

/// Where and how far to zoom at a moment of the recording. Pure math, so
/// the export and the preview can never disagree.
enum ZoomTimeline {
    struct Window: Equatable { var start: Double; var end: Double; var x: Double; var y: Double }
    struct Zoom: Equatable { var scale: CGFloat; var x: Double; var y: Double }

    /// Clicks closer together than `gap` share one zoom window centred on
    /// their average; each window holds for `hold` seconds after its last click.
    static func windows(for clicks: [RecordedClick], hold: Double = 1.8, gap: Double = 1.2, lead: Double = 0.35) -> [Window] {
        var result: [Window] = []
        var cluster: [RecordedClick] = []
        func flush() {
            guard let first = cluster.first, let last = cluster.last else { return }
            let x = cluster.map(\.x).reduce(0, +) / Double(cluster.count)
            let y = cluster.map(\.y).reduce(0, +) / Double(cluster.count)
            result.append(Window(start: max(0, first.time - lead), end: last.time + hold, x: x, y: y))
            cluster = []
        }
        for click in clicks.sorted(by: { $0.time < $1.time }) {
            if let last = cluster.last, click.time - last.time > gap { flush() }
            cluster.append(click)
        }
        flush()
        return result
    }

    private static func smoothstep(_ t: Double) -> Double { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }

    /// Scale 1 means no zoom. Ramps in and out over `ease` seconds; between
    /// windows the frame returns to full view.
    static func zoom(at time: Double, windows: [Window], scale: CGFloat, ease: Double = 0.4) -> Zoom {
        guard scale > 1 else { return Zoom(scale: 1, x: 0.5, y: 0.5) }
        var best = Zoom(scale: 1, x: 0.5, y: 0.5)
        for window in windows {
            let inRamp = smoothstep((time - window.start) / ease)
            let outRamp = smoothstep((window.end - time) / ease)
            let amount = min(inRamp, outRamp)
            guard amount > 0 else { continue }
            let current = 1 + (scale - 1) * CGFloat(amount)
            if current > best.scale { best = Zoom(scale: current, x: window.x, y: window.y) }
        }
        return best
    }

    /// The source rectangle to show at this zoom, kept inside the frame.
    static func cropRect(for zoom: Zoom, in size: CGSize) -> CGRect {
        let w = size.width / zoom.scale, h = size.height / zoom.scale
        let x = min(max(0, size.width * zoom.x - w / 2), size.width - w)
        let y = min(max(0, size.height * zoom.y - h / 2), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct PolishOptions: Equatable {
    var trimStart: Double = 0
    var trimEnd: Double? = nil
    var backdrop: BackdropStyle = .ocean
    var customColor: NSColor = BackdropStyle.ocean.colors![0]
    var zoomOnClicks = true
    var zoomScale: CGFloat = 1.8
    var cornerRadius: CGFloat = 18
    var paddingFraction: CGFloat = 0.06
    /// Draw the cursor from the sampled track (only sensible when the movie
    /// was recorded without the system cursor).
    var drawCursor = false
    var smoothCursor = true
    var cursorSize: CGFloat = 1.6
    var showKeystrokes = false
    var motionBlur = true

    var hasBackdrop: Bool { backdrop != .none }
}

enum RecordingPolish {
    /// The output beside the source: "Recording X.mov" → "Recording X — polished.mp4".
    static func outputURL(for source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("polished.mp4")
    }

    struct Frame {
        let source: CGSize
        let padding: CGFloat
        let output: CGSize
    }

    static func frame(for source: CGSize, options: PolishOptions) -> Frame {
        let pad = options.hasBackdrop ? max(32, (source.width * options.paddingFraction).rounded()) : 0
        return Frame(source: source, padding: pad,
                     output: CGSize(width: (source.width + pad * 2).rounded(), height: (source.height + pad * 2).rounded()))
    }

    /// One frame: zoom toward the clicks, then sit on the backdrop with
    /// rounded corners and a soft shadow. Everything except the zoom is built
    /// once and reused for every frame.
    final class Renderer: @unchecked Sendable {
        let frame: Frame
        let options: PolishOptions
        let windows: [ZoomTimeline.Window]
        private let backdrop: CIImage?
        private let shadow: CIImage?
        private let mask: CIImage?
        private let cursor: CursorTrack?
        private let cursorImage: CIImage?
        private let cursorHotspot: CGPoint
        private let keystrokes: [RecordedKeystroke]
        private var keyPills: [String: CIImage] = [:]
        private let lock = NSLock()
        static let keystrokeLife = 1.3

        init(size: CGSize, options: PolishOptions, clicks: [RecordedClick], cursor: CursorTrack? = nil, keystrokes: [RecordedKeystroke] = []) {
            self.frame = RecordingPolish.frame(for: size, options: options)
            self.options = options
            self.windows = options.zoomOnClicks ? ZoomTimeline.windows(for: clicks) : []
            self.cursor = options.drawCursor ? cursor : nil
            self.keystrokes = options.showKeystrokes ? keystrokes : []
            let arrow = NSCursor.arrow
            if options.drawCursor, let cg = arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Size relative to the video, not the screen: 1× reads like the
                // system cursor on a 1440-wide capture.
                let base = max(0.8, size.width / 1440) * options.cursorSize
                cursorImage = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: base, y: base))
                cursorHotspot = CGPoint(x: arrow.hotSpot.x * base, y: arrow.hotSpot.y * base)
            } else { cursorImage = nil; cursorHotspot = .zero }
            let outputRect = CGRect(origin: .zero, size: frame.output)
            if options.hasBackdrop {
                backdrop = Self.backdropImage(options: options, size: frame.output)
                let card = CGRect(x: frame.padding, y: frame.padding, width: size.width, height: size.height)
                mask = Self.roundedMask(rect: card, radius: options.cornerRadius, canvas: outputRect)
                shadow = Self.roundedMask(rect: card.offsetBy(dx: 0, dy: -8), radius: options.cornerRadius, canvas: outputRect)
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
                                                                  "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                  "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                  "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
                    .cropped(to: outputRect)
            } else { backdrop = nil; mask = nil; shadow = nil }
        }

        func render(_ image: CIImage, at time: Double) -> CIImage {
            let bounds = image.extent
            var output = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            // The cursor goes on BEFORE zooming so it magnifies with the frame.
            if let cursor, let cursorImage, let p = cursor.position(at: time, smoothed: options.smoothCursor) {
                let tip = CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
                let placed = cursorImage.transformed(by: CGAffineTransform(
                    translationX: tip.x - cursorHotspot.x, y: tip.y - (cursorImage.extent.height - cursorHotspot.y)))
                output = placed.composited(over: output).cropped(to: CGRect(origin: .zero, size: bounds.size))
            }
            let zoom = ZoomTimeline.zoom(at: time, windows: windows, scale: options.zoomScale)
            if zoom.scale > 1.001 {
                // Fractions are top-left; Core Image is bottom-left.
                let crop = ZoomTimeline.cropRect(for: ZoomTimeline.Zoom(scale: zoom.scale, x: zoom.x, y: 1 - zoom.y), in: bounds.size)
                output = output.cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(by: CGAffineTransform(scaleX: zoom.scale, y: zoom.scale))
                    .cropped(to: CGRect(origin: .zero, size: bounds.size))
                if options.motionBlur {
                    // Blur only while the zoom is moving, in proportion to how fast.
                    let ahead = ZoomTimeline.zoom(at: time + 1 / 60, windows: windows, scale: options.zoomScale)
                    let velocity = abs(ahead.scale - zoom.scale) * 60
                    if velocity > 0.05 {
                        let centre = CIVector(x: zoom.x * bounds.width, y: (1 - zoom.y) * bounds.height)
                        output = output.applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: centre, kCIInputAmountKey: min(18, velocity * 6)])
                            .cropped(to: CGRect(origin: .zero, size: bounds.size))
                    }
                }
            }
            for key in keystrokes where time >= key.t && time < key.t + Self.keystrokeLife {
                let pill = pillImage(for: key.label, width: bounds.width)
                let age = time - key.t
                let alpha = age > Self.keystrokeLife - 0.3 ? (Self.keystrokeLife - age) / 0.3 : 1
                let placed = pill
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                    .transformed(by: CGAffineTransform(translationX: (bounds.width - pill.extent.width) / 2, y: bounds.height * 0.06))
                output = placed.composited(over: output).cropped(to: CGRect(origin: .zero, size: bounds.size))
            }
            guard let backdrop, let mask, let shadow else { return output }
            let card = output.transformed(by: CGAffineTransform(translationX: frame.padding, y: frame.padding))
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
            return card.composited(over: shadow.composited(over: backdrop)).cropped(to: CGRect(origin: .zero, size: frame.output))
        }

        /// A dark pill with the chord in it; built once per distinct label.
        private func pillImage(for label: String, width: CGFloat) -> CIImage {
            lock.lock(); defer { lock.unlock() }
            if let cached = keyPills[label] { return cached }
            let fontSize = max(14, min(34, width / 40))
            let font = NSFont(name: "Gellix-SemiBold", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let measured = (label as NSString).size(withAttributes: attributes)
            let size = CGSize(width: ceil(measured.width + fontSize * 1.4), height: ceil(measured.height + fontSize * 0.7))
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.withAlphaComponent(0.78).setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
                (label as NSString).draw(at: CGPoint(x: (rect.width - measured.width) / 2, y: (rect.height - measured.height) / 2), withAttributes: attributes)
                return true
            }
            let result = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CIImage(cgImage: $0) } ?? CIImage.empty()
            keyPills[label] = result
            return result
        }

        private static func backdropImage(options: PolishOptions, size: CGSize) -> CIImage {
            let rect = CGRect(origin: .zero, size: size)
            if let colors = options.backdrop.colors, colors.count == 2 {
                let gradient = CIFilter.linearGradient()
                gradient.color0 = CIColor(color: colors[0]) ?? .white
                gradient.color1 = CIColor(color: colors[1]) ?? .black
                gradient.point0 = CGPoint(x: 0, y: size.height)
                gradient.point1 = CGPoint(x: size.width, y: 0)
                return (gradient.outputImage ?? CIImage(color: .black)).cropped(to: rect)
            }
            return CIImage(color: CIColor(color: options.customColor) ?? .black).cropped(to: rect)
        }

        private static func roundedMask(rect: CGRect, radius: CGFloat, canvas: CGRect) -> CIImage {
            let image = NSImage(size: canvas.size, flipped: false) { _ in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return CIImage.empty() }
            return CIImage(cgImage: cg)
        }
    }

    /// Writes the polished copy. Audio passes through untouched; video is
    /// re-rendered through `Renderer` and encoded with the Mac's hardware
    /// encoder when HEVC is available.
    static func export(source: URL, to destination: URL, options: PolishOptions, clicks: [RecordedClick],
                       cursor: CursorTrack? = nil, keystrokes: [RecordedKeystroke] = [],
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AgentError("INVALID_VIDEO", "Missing video track.") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let renderer = Renderer(size: size, options: options, clicks: clicks, cursor: cursor, keystrokes: keystrokes)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: renderer.render(request.sourceImage, at: request.compositionTime.seconds), context: nil)
        }
        composition.renderSize = renderer.frame.output
        let start = min(max(0, options.trimStart), max(0, duration - 0.1))
        let end = min(options.trimEnd ?? duration, duration)
        guard end - start >= 0.1 else { throw AgentError("INVALID_ARGUMENTS", "Keep at least a tenth of a second of the recording.") }
        let presets = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        guard let preset = presets.first(where: { AVAssetExportSession.exportPresets(compatibleWith: asset).contains($0) }),
              let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AgentError("EXPORT_FAILED", "No export preset is available for this recording.")
        }
        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.videoComposition = composition
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        exporter.shouldOptimizeForNetworkUse = true
        let poll = Task { while !Task.isCancelled { progress(Double(exporter.progress)); try? await Task.sleep(for: .milliseconds(200)) } }
        await exporter.export()
        poll.cancel()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw AgentError("EXPORT_FAILED", exporter.error?.localizedDescription ?? "Video export failed.")
        }
        progress(1)
    }
}

// MARK: - Cursor track and keystrokes (the rest of Studio Mode)

struct CursorSample: Codable, Equatable, Sendable {
    var t: Double
    var x: Double
    var y: Double
}

/// Cursor positions sampled through the recording. `separate` records
/// whether the movie itself was captured WITHOUT the system cursor, which
/// is what lets Polish draw a smoothed, resized one instead.
struct CursorTrack: Codable, Equatable, Sendable {
    var separate: Bool
    var samples: [CursorSample]

    /// The cursor at `time`: a short weighted average of nearby samples
    /// when smoothing, the nearest sample otherwise. Nil before the first
    /// sample or after the last.
    func position(at time: Double, smoothed: Bool, window: Double = 0.07) -> CGPoint? {
        guard let first = samples.first, let last = samples.last, time >= first.t - 0.05, time <= last.t + 0.05 else { return nil }
        if smoothed {
            var wx = 0.0, wy = 0.0, total = 0.0
            for sample in samples where abs(sample.t - time) <= window {
                let weight = 1 - abs(sample.t - time) / window
                wx += sample.x * weight; wy += sample.y * weight; total += weight
            }
            if total > 0 { return CGPoint(x: wx / total, y: wy / total) }
        }
        let nearest = samples.min { abs($0.t - time) < abs($1.t - time) }!
        return CGPoint(x: nearest.x, y: nearest.y)
    }
}

struct RecordedKeystroke: Codable, Equatable, Sendable {
    var t: Double
    var label: String
}

enum RecordingSidecars {
    static func cursorURL(for movie: URL) -> URL { movie.appendingPathExtension("cursor.json") }
    static func keysURL(for movie: URL) -> URL { movie.appendingPathExtension("keys.json") }

    static func save(cursor: CursorTrack, for movie: URL) {
        guard !cursor.samples.isEmpty, let data = try? JSONEncoder().encode(cursor) else { return }
        try? data.write(to: cursorURL(for: movie), options: .atomic)
    }
    static func loadCursor(for movie: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: cursorURL(for: movie)), let track = try? JSONDecoder().decode(CursorTrack.self, from: data) else { return nil }
        return CursorTrack(separate: track.separate, samples: track.samples.filter { $0.t.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }.sorted { $0.t < $1.t })
    }
    static func save(keys: [RecordedKeystroke], for movie: URL) {
        guard !keys.isEmpty, let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: keysURL(for: movie), options: .atomic)
    }
    static func loadKeys(for movie: URL) -> [RecordedKeystroke] {
        guard let data = try? Data(contentsOf: keysURL(for: movie)), let keys = try? JSONDecoder().decode([RecordedKeystroke].self, from: data) else { return [] }
        return keys.filter { $0.t.isFinite && !$0.label.isEmpty }.sorted { $0.t < $1.t }
    }
}

/// Samples the cursor at 60 Hz while a recording runs.
@MainActor
final class CursorTrackRecorder {
    private(set) var samples: [CursorSample] = []
    private var timer: Timer?
    private let region: CGRect
    private let startedAt: Date
    let separate: Bool

    init(regionAppKit: CGRect, startedAt: Date, separate: Bool) {
        region = regionAppKit; self.startedAt = startedAt; self.separate = separate
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.record(location) }
        }
    }

    func record(_ location: CGPoint, at date: Date = Date()) {
        guard region.width > 0, region.height > 0 else { return }
        let x = (location.x - region.minX) / region.width, y = 1 - (location.y - region.minY) / region.height
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        samples.append(CursorSample(t: date.timeIntervalSince(startedAt), x: x, y: y))
    }

    func stop() -> CursorTrack {
        timer?.invalidate(); timer = nil
        return CursorTrack(separate: separate, samples: samples)
    }
}

/// Logs keyboard shortcuts while a recording runs. Only chords with ⌘, ⌃
/// or ⌥ and navigation keys are kept — never what someone types.
@MainActor
final class KeystrokeRecorder {
    private(set) var keys: [RecordedKeystroke] = []
    private var monitor: Any?
    private let startedAt: Date

    static var isAvailable: Bool { AXIsProcessTrusted() }

    init(startedAt: Date) {
        self.startedAt = startedAt
        guard Self.isAvailable else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let label = KeystrokeRecorder.label(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
            Task { @MainActor in if let label { self?.record(label) } }
        }
    }

    func record(_ label: String, at date: Date = Date()) {
        keys.append(RecordedKeystroke(t: date.timeIntervalSince(startedAt), label: label))
    }

    func stop() -> [RecordedKeystroke] {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        return keys
    }

    nonisolated private static let navigationKeys: [UInt32: String] = [
        UInt32(kVK_Return): "⏎", UInt32(kVK_Escape): "esc", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Space): "space",
    ]

    /// "⇧⌘S", "⌘V", "esc"; nil for plain typing.
    nonisolated static func label(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let chord = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        let navigation = navigationKeys[keyCode]
        guard chord || navigation != nil else { return nil }
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        let name = navigation ?? HotkeyCombo.keyName(keyCode)
        guard !name.hasPrefix("key") else { return nil }
        return parts + name
    }
}
