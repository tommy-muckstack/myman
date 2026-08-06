import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
@preconcurrency import Vision

// All annotation geometry lives in IMAGE coordinates (points, top-left origin)
// so the on-screen preview and the full-resolution export can never disagree.

enum Annotation: Identifiable, Equatable {
    case arrow(id: UUID, from: CGPoint, to: CGPoint)
    case box(id: UUID, rect: CGRect)
    case highlight(id: UUID, rect: CGRect)
    case text(id: UUID, string: String, origin: CGPoint)
    case pixelate(id: UUID, rect: CGRect)
    /// Overlaid photo; the NSImage lives in EditorModel.overlayImages[id].
    case image(id: UUID, rect: CGRect)

    var id: UUID {
        switch self {
        case .arrow(let id, _, _), .box(let id, _), .highlight(let id, _),
             .text(let id, _, _), .pixelate(let id, _), .image(let id, _):
            return id
        }
    }
}

enum BackdropStyle: String, CaseIterable, Identifiable {
    case none = "None"
    case dusk = "Dusk"
    case ocean = "Ocean"
    case meadow = "Meadow"
    case slate = "Slate"

    var id: String { rawValue }

    var colors: [NSColor]? {
        switch self {
        case .none: return nil
        case .dusk: return [NSColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                            NSColor(red: 0.58, green: 0.32, blue: 0.62, alpha: 1)]
        case .ocean: return [NSColor(red: 0.30, green: 0.62, blue: 0.94, alpha: 1),
                             NSColor(red: 0.12, green: 0.24, blue: 0.48, alpha: 1)]
        case .meadow: return [NSColor(red: 0.55, green: 0.85, blue: 0.60, alpha: 1),
                              NSColor(red: 0.13, green: 0.42, blue: 0.34, alpha: 1)]
        case .slate: return [NSColor(white: 0.28, alpha: 1), NSColor(white: 0.10, alpha: 1)]
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var image: NSImage
    @Published var annotations: [Annotation] = []
    @Published var backdrop: BackdropStyle = .none
    @Published var isRemovingBackground = false
    @Published var backgroundRemoved = false
    /// Rounded-corner radius applied to the image itself (0 = square).
    @Published var cornerRadius: CGFloat = 0
    @Published var didCopyText = false
    /// OCR text lines with geometry — loaded on first use of the text tool.
    @Published var textObservations: [ImageAnalysis.TextObservation]?
    @Published var isLoadingText = false

    /// Lens-style in-place translation layer. Toggleable; baked into
    /// renders while shown. Cleared by crop/background removal (geometry
    /// no longer matches).
    @Published var translationPatches: [TranslationPatch] = []
    @Published var showTranslation = true

    /// Cached previews of pixelated regions, keyed by annotation id.
    @Published var pixelatePreviews: [UUID: NSImage] = [:]
    /// Backing images for .image annotations.
    @Published var overlayImages: [UUID: NSImage] = [:]

    static let highlightColor = NSColor(red: 1.0, green: 0.86, blue: 0.20, alpha: 0.4)

    let fileURL: URL
    private var imageHistory: [NSImage] = []

    var annotationColor: NSColor { NSColor(red: 1.0, green: 0.22, blue: 0.36, alpha: 1) }

    /// Corner rounding on the image: the user's choice, or a minimum of 12
    /// whenever a backdrop is on (a hard-corner shot on a gradient looks wrong).
    var effectiveCornerRadius: CGFloat {
        backdrop == .none ? cornerRadius : max(cornerRadius, 12)
    }

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
    }

    var imageSize: CGSize { image.size }

    // MARK: Annotations

    /// One font size for text annotations, in image points — the preview and
    /// the export both derive from this so they can never disagree.
    var annotationFontSize: CGFloat { max(14, imageSize.width / 40) }

    private var annotationFont: NSFont {
        NSFont(name: "Outfit-SemiBold", size: annotationFontSize)
            ?? NSFont.boldSystemFont(ofSize: annotationFontSize)
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        if case .pixelate(let id, let rect) = annotation {
            pixelatePreviews[id] = Self.pixelated(image, in: rect)
        }
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        pixelatePreviews[id] = nil
        overlayImages[id] = nil
    }

    /// Insert a photo as a movable overlay, centered, at ≤40% of image width.
    func addOverlayImage(_ overlay: NSImage) {
        let id = UUID()
        let maxWidth = imageSize.width * 0.4
        let scale = min(1, maxWidth / max(overlay.size.width, 1))
        let size = CGSize(width: overlay.size.width * scale, height: overlay.size.height * scale)
        let rect = CGRect(
            x: (imageSize.width - size.width) / 2,
            y: (imageSize.height - size.height) / 2,
            width: size.width, height: size.height
        )
        overlayImages[id] = overlay
        annotations.append(.image(id: id, rect: rect))
    }

    /// Crop the working image to `rect` (image coords, top-left origin).
    /// Annotations translate with the crop; ones left fully outside are dropped.
    func applyCrop(_ rect: CGRect) {
        translationPatches = []
        let target = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard target.width > 10, target.height > 10,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let pixelScale = CGFloat(cgImage.width) / imageSize.width
        let pixelRect = CGRect(
            x: target.origin.x * pixelScale, y: target.origin.y * pixelScale,
            width: target.width * pixelScale, height: target.height * pixelScale
        ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = cgImage.cropping(to: pixelRect) else { return }

        imageHistory.append(image)
        image = NSImage(cgImage: cropped, size: target.size)

        let delta = CGVector(dx: -target.origin.x, dy: -target.origin.y)
        let visible = CGRect(origin: .zero, size: target.size)
        for annotation in annotations {
            move(annotation.id, by: delta)
        }
        annotations.removeAll { !bounds(of: $0).intersects(visible) }
        for annotation in annotations {
            refreshPixelateIfNeeded(annotation.id)
        }
    }

    /// OCR the current image and put the recognized text on the clipboard.
    func copyRecognizedText() {
        let snapshot = image
        Task { @MainActor in
            let analysis = await ImageAnalysis.analyze(snapshot)
            guard !analysis.text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(analysis.text, forType: .string)
            didCopyText = true
            Analytics.track("editor_text_copied", ["chars": analysis.text.count])
            try? await Task.sleep(for: .seconds(2))
            didCopyText = false
        }
    }

    func undo() {
        if let last = annotations.popLast() {
            pixelatePreviews[last.id] = nil
        } else if let previous = imageHistory.popLast() {
            image = previous
            backgroundRemoved = false
        }
    }

    func loadTextObservations() {
        guard textObservations == nil, !isLoadingText else { return }
        isLoadingText = true
        let snapshot = image
        Task { @MainActor in
            textObservations = await ImageAnalysis.textObservations(snapshot)
            isLoadingText = false
        }
    }

    /// Copy the text of every observation intersecting `rect` (image coords).
    /// Returns how many lines were copied.
    @discardableResult
    func copyText(in rect: CGRect) -> Int {
        let hits = (textObservations ?? [])
            .filter { $0.rect(in: imageSize).intersects(rect) }
        guard !hits.isEmpty else { return 0 }
        let text = hits.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Analytics.track("editor_text_copied", ["chars": text.count])
        didCopyText = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopyText = false
        }
        return hits.count
    }

    // MARK: Hit-testing & moving (image coords)

    func bounds(of annotation: Annotation) -> CGRect {
        switch annotation {
        case .arrow(_, let from, let to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        case .box(_, let rect), .highlight(_, let rect), .pixelate(_, let rect), .image(_, let rect):
            return rect
        case .text(_, let string, let origin):
            // Measured with AppKit metrics but DRAWN by SwiftUI — the two can
            // disagree, so the grab box is padded generously: full line height
            // plus width headroom. A text you can see is a text you can grab.
            let measured = (string as NSString).size(withAttributes: [.font: annotationFont])
            return CGRect(
                x: origin.x - 4,
                y: origin.y - 4,
                width: max(measured.width * 1.25, annotationFontSize * 2) + 8,
                height: max(measured.height, annotationFontSize * 1.4) + 8
            )
        }
    }

    /// Topmost annotation under the point, or nil. `tolerance` is in image
    /// points — callers derive it from VIEW pixels (÷ display scale) so grab
    /// targets feel the same size regardless of zoom. Rects (box, text,
    /// pixelate) hit anywhere inside their expanded bounds; arrows hit along
    /// the line. To draw INSIDE an existing box, start the drag outside it.
    func hitTest(_ point: CGPoint, tolerance: CGFloat, selected: UUID? = nil) -> UUID? {
        for annotation in annotations.reversed() {
            switch annotation {
            case .arrow(_, let from, let to):
                if distance(from: point, toSegment: (from, to)) <= tolerance {
                    return annotation.id
                }
            case .box, .highlight, .text, .pixelate, .image:
                if bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance)
                    .contains(point) {
                    return annotation.id
                }
            }
        }
        return nil
    }

    func move(_ id: UUID, by delta: CGVector) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index] {
        case .arrow(let id, let from, let to):
            annotations[index] = .arrow(
                id: id,
                from: CGPoint(x: from.x + delta.dx, y: from.y + delta.dy),
                to: CGPoint(x: to.x + delta.dx, y: to.y + delta.dy)
            )
        case .box(let id, let rect):
            annotations[index] = .box(id: id, rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .highlight(let id, let rect):
            annotations[index] = .highlight(id: id, rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .pixelate(let id, let rect):
            annotations[index] = .pixelate(id: id, rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .image(let id, let rect):
            annotations[index] = .image(id: id, rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .text(let id, let string, let origin):
            annotations[index] = .text(
                id: id, string: string,
                origin: CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy)
            )
        }
    }

    /// Pixelation shows the pixels UNDER the region, so a moved region must
    /// re-sample. Called once on drag end, not per drag tick.
    func refreshPixelateIfNeeded(_ id: UUID) {
        guard case .pixelate(_, let rect)? = annotations.first(where: { $0.id == id }) else { return }
        pixelatePreviews[id] = Self.pixelated(image, in: rect)
    }

    private func distance(from p: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let abX = b.x - a.x, abY = b.y - a.y
        let lengthSquared = abX * abX + abY * abY
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abX + (p.y - a.y) * abY) / lengthSquared))
        return hypot(p.x - (a.x + t * abX), p.y - (a.y + t * abY))
    }

    // MARK: Background removal (Vision subject mask → transparent background)

    func removeBackground() {
        translationPatches = []
        guard !isRemovingBackground, !backgroundRemoved,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        isRemovingBackground = true
        let size = image.size

        Task.detached(priority: .userInitiated) {
            let masked: CGImage? = {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                guard (try? handler.perform([request])) != nil,
                      let result = request.results?.first,
                      let maskBuffer = try? result.generateScaledMaskForImage(
                          forInstances: result.allInstances, from: handler)
                else { return nil }

                let input = CIImage(cgImage: cgImage)
                let filter = CIFilter.blendWithMask()
                filter.inputImage = input
                filter.maskImage = CIImage(cvPixelBuffer: maskBuffer)
                filter.backgroundImage = CIImage(color: .clear).cropped(to: input.extent)
                guard let output = filter.outputImage else { return nil }
                return CIContext().createCGImage(output, from: output.extent)
            }()

            await MainActor.run {
                self.isRemovingBackground = false
                guard let masked else { return }
                self.imageHistory.append(self.image)
                self.image = NSImage(cgImage: masked, size: size)
                self.backgroundRemoved = true
                Analytics.track("editor_background_removed")
                // A cut-out subject begs for a backdrop.
                if self.backdrop == .none { self.backdrop = .slate }
            }
        }
    }

    /// Bounding box of non-transparent pixels (scanned on a ≤256px alpha-only
    /// downsample, scaled back up), with a small margin.
    nonisolated private static func cropToOpaqueBounds(_ image: CGImage) -> CGImage? {
        let thumbWidth = min(256, image.width)
        let ratio = CGFloat(thumbWidth) / CGFloat(image.width)
        let thumbHeight = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(
            data: nil, width: thumbWidth, height: thumbHeight,
            bitsPerComponent: 8, bytesPerRow: thumbWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        guard let data = context.data else { return image }
        let bytes = data.bindMemory(to: UInt8.self, capacity: thumbWidth * thumbHeight)

        var minX = thumbWidth, minY = thumbHeight, maxX = -1, maxY = -1
        for y in 0..<thumbHeight {
            for x in 0..<thumbWidth where bytes[y * thumbWidth + x] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        // Back to full-resolution pixels, with ~3% breathing room.
        let inv = 1 / ratio
        let margin = CGFloat(max(image.width, image.height)) * 0.03
        // Alpha-only context rows are top-down like CGImage — no flip needed.
        var rect = CGRect(
            x: CGFloat(minX) * inv - margin,
            y: CGFloat(minY) * inv - margin,
            width: CGFloat(maxX - minX + 1) * inv + margin * 2,
            height: CGFloat(maxY - minY + 1) * inv + margin * 2
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: rect) ?? image
    }

    // MARK: Pixelation

    nonisolated static func pixelated(_ image: NSImage, in rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: (image.size.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !pixelRect.isEmpty, let crop = cgImage.cropping(to: pixelRect) else { return nil }

        let input = CIImage(cgImage: crop)
        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(max(8, pixelRect.width / 24))
        filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgOut = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgOut, size: rect.size)
    }

    // MARK: Export — full-resolution render of image + annotations + backdrop

    func renderFinal() -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let pixelScale = CGFloat(cgImage.width) / image.size.width
        let contentSize = image.size

        // Backdrop adds breathing room: 6% padding, rounded image corners.
        let pad = backdrop == .none ? 0 : max(32, contentSize.width * 0.06)
        let canvasSize = CGSize(width: contentSize.width + pad * 2, height: contentSize.height + pad * 2)

        let result = NSImage(size: canvasSize)
        result.lockFocusFlipped(false)
        defer { result.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        if let colors = backdrop.colors {
            let gradient = NSGradient(colors: colors)
            gradient?.draw(in: NSRect(origin: .zero, size: canvasSize), angle: -60)
        } else if effectiveCornerRadius > 0, !backgroundRemoved {
            // Rounded corners on a plain screenshot: black behind, not
            // transparency.
            NSColor.black.setFill()
            NSRect(origin: .zero, size: canvasSize).fill()
        }

        let imageRect = CGRect(x: pad, y: pad, width: contentSize.width, height: contentSize.height)
        let radius = effectiveCornerRadius
        if backdrop != .none || radius > 0 {
            ctx.saveGState()
            if backdrop != .none {
                ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
            }
            let path = NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius)
            path.addClip()
            image.draw(in: imageRect)
            ctx.restoreGState()
        } else {
            image.draw(in: imageRect)
        }

        if showTranslation {
            for patch in translationPatches {
                InPlaceTranslation.draw(patch, imageRect: imageRect,
                                        imageHeight: contentSize.height)
            }
        }

        // Annotations (image coords are top-left origin; this context is bottom-left).
        func flip(_ p: CGPoint) -> CGPoint {
            CGPoint(x: pad + p.x, y: pad + contentSize.height - p.y)
        }
        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: pad + r.origin.x, y: pad + contentSize.height - r.maxY,
                   width: r.width, height: r.height)
        }

        for annotation in annotations {
            switch annotation {
            case .pixelate(let id, let rect):
                pixelatePreviews[id]?.draw(in: flip(rect))

            case .highlight(_, let rect):
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(Self.highlightColor.cgColor)
                ctx.fill(flip(rect))
                ctx.restoreGState()

            case .image(let id, let rect):
                overlayImages[id]?.draw(in: flip(rect))

            case .box(_, let rect):
                ctx.setStrokeColor(annotationColor.cgColor)
                ctx.setLineWidth(3)
                let path = NSBezierPath(roundedRect: flip(rect), xRadius: 3, yRadius: 3)
                path.lineWidth = 3
                annotationColor.setStroke()
                path.stroke()

            case .arrow(_, let from, let to):
                drawArrow(from: flip(from), to: flip(to), in: ctx)

            case .text(_, let string, let origin):
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont(name: "Outfit-SemiBold", size: annotationFontSize)
                        ?? NSFont.boldSystemFont(ofSize: annotationFontSize),
                    .foregroundColor: annotationColor,
                ]
                let flipped = flip(origin)
                (string as NSString).draw(
                    at: CGPoint(x: flipped.x, y: flipped.y - annotationFontSize * 1.2),
                    withAttributes: attributes
                )
            }
        }

        _ = pixelScale // full-res render comes via draw(in:) of the original reps
        return result
    }

    private func drawArrow(from: CGPoint, to: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(annotationColor.cgColor)
        ctx.setFillColor(annotationColor.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength: CGFloat = 14
        let lineEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.6,
            y: to.y - sin(angle) * headLength * 0.6
        )
        ctx.move(to: from)
        ctx.addLine(to: lineEnd)
        ctx.strokePath()

        let tip = to
        let left = CGPoint(
            x: to.x - headLength * cos(angle - .pi / 7),
            y: to.y - headLength * sin(angle - .pi / 7)
        )
        let right = CGPoint(
            x: to.x - headLength * cos(angle + .pi / 7),
            y: to.y - headLength * sin(angle + .pi / 7)
        )
        ctx.move(to: tip)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Output

    func copyToClipboard() {
        let final = renderFinal()
        guard let tiff = final.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// Overwrites the original capture file with the edited render.
    func save() {
        Analytics.track("editor_saved", [
            "annotations": annotations.count,
            "backdrop": backdrop.rawValue,
            "cutout": backgroundRemoved,
            "corner_radius": Int(cornerRadius),
        ])
        let final = renderFinal()
        guard let tiff = final.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: fileURL)
        copyToClipboard()
    }
}
