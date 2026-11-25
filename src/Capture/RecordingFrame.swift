import AppKit
import CoreImage
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// Puts each recorded frame on a Loom-style card: the screen sits in a rounded
/// rectangle with a soft shadow, on a gradient in the frame color. The saved
/// video is the screen plus a border on every side, so the screen keeps its pixels.
final class RecordingFrameComposer: @unchecked Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let padding: Int
    let outputWidth: Int
    let outputHeight: Int
    /// Called with a small copy of each composed frame, a few times a second, for the live preview.
    var onPreview: ((CGImage) -> Void)?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let outputRect: CGRect
    private let cardRect: CGRect
    private let backdrop: CIImage
    private let shadow: CIImage
    private let mask: CIImage
    private var pool: CVPixelBufferPool?
    private var lastPreview: CFTimeInterval = 0

    /// Space around the screen on every side: 6% of the width, at least 32 points.
    static func padding(forWidth width: Int) -> Int {
        max(32, Int((CGFloat(width) * 0.06).rounded()))
    }

    init(sourceWidth: Int, sourceHeight: Int, color: NSColor) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        let pad = Self.padding(forWidth: sourceWidth)
        padding = pad
        outputWidth = (sourceWidth + 2 * pad) & ~1
        outputHeight = (sourceHeight + 2 * pad) & ~1
        outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        cardRect = CGRect(x: pad, y: pad, width: sourceWidth, height: sourceHeight)
        let radius = max(12, min(28, CGFloat(sourceWidth) * 0.012))
        let rgb = color.usingColorSpace(.sRGB) ?? .systemBlue
        let deep = rgb.blended(withFraction: 0.35, of: .black) ?? rgb
        backdrop = Self.gradient(top: rgb, bottom: deep, in: outputRect)
        let card = cardRect
        mask = Self.image(size: outputRect.size) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        shadow = mask
            .transformed(by: CGAffineTransform(translationX: 0, y: -10))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.4),
            ])
            .cropped(to: outputRect)
    }

    /// Composes one captured frame. Nil when the buffer is not the size this composer was made for.
    func compose(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(buffer) == sourceWidth, CVPixelBufferGetHeight(buffer) == sourceHeight,
              let output = makeOutputBuffer() else { return nil }
        let image = framed(CIImage(cvPixelBuffer: buffer))
        context.render(image, to: output, bounds: outputRect, colorSpace: colorSpace)
        notePreview(image)
        return output
    }

    /// The framed look of a still image, for the preview before recording starts.
    func framedImage(from still: CGImage) -> CGImage? {
        let scale = CGAffineTransform(scaleX: CGFloat(sourceWidth) / CGFloat(still.width),
                                      y: CGFloat(sourceHeight) / CGFloat(still.height))
        let image = framed(CIImage(cgImage: still).transformed(by: scale))
        return context.createCGImage(image, from: outputRect)
    }

    private func framed(_ source: CIImage) -> CIImage {
        let card = source
            .transformed(by: CGAffineTransform(translationX: CGFloat(padding), y: CGFloat(padding)))
            .cropped(to: cardRect)
        let rounded = card.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        return rounded.composited(over: shadow.composited(over: backdrop)).cropped(to: outputRect)
    }

    /// Small previews, at most about five a second, so the preview costs little next to the encoder.
    private func notePreview(_ image: CIImage) {
        let now = CACurrentMediaTime()
        guard now - lastPreview >= 0.2, let onPreview else { return }
        lastPreview = now
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        if let preview = context.createCGImage(small, from: small.extent) { onPreview(preview) }
    }

    private func makeOutputBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: outputWidth,
                kCVPixelBufferHeightKey: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attributes as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private static func gradient(top: NSColor, bottom: NSColor, in rect: CGRect) -> CIImage {
        let start = CIColor(color: bottom) ?? CIColor.black
        let end = CIColor(color: top) ?? CIColor.white
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputColor0": start,
            "inputPoint1": CIVector(x: 0, y: rect.height),
            "inputColor1": end,
        ])
        return (filter?.outputImage ?? CIImage(color: start)).cropped(to: rect)
    }

    /// A transparent image with white where `draw` paints. Its alpha is the shape.
    private static func image(size: CGSize, draw: (CGContext) -> Void) -> CIImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return CIImage(cgImage: context.makeImage()!)
    }
}

final class FramePreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var aspect: CGFloat = 0.6
}

/// The floating preview of what will be saved. It shows during the countdown, from a still of the
/// region, and then live while recording. It sits outside the captured area and is never recorded.
@MainActor
final class RecordingFramePreview {
    static let shared = RecordingFramePreview()

    private let model = FramePreviewModel()
    private var panel: FloatingPanel?
    private var region: CGRect?
    private var still: CGImage?
    private var composer: RecordingFrameComposer?
    private var colorObserver: NSObjectProtocol?

    /// The preview's window, so the recording leaves it out.
    var windowNumber: Int? { panel?.windowNumber }

    func show(region: CGRect) {
        self.region = region
        if panel == nil {
            let view = FramePreviewView(model: model)
            let created = FloatingPanel(content: view, becomesKey: false, fixedSize: true, acceptsFirstClick: false)
            created.dismissesOnResign = false
            created.isMovableByWindowBackground = false
            created.ignoresMouseEvents = true
            panel = created
            colorObserver = NotificationCenter.default.addObserver(
                forName: RecordingFrameStyle.changed, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecordingFramePreview.shared.recolor() }
            }
        }
        model.aspect = region.width > 0 ? region.height / region.width : 0.6
        place()
        panel?.orderFrontRegardless()
        if #available(macOS 15.0, *) {
            Task { [weak self] in
                guard let image = try? await Self.still(of: region) else { return }
                self?.setStill(image)
            }
        }
    }

    /// Live frames from the encoder while recording.
    func update(_ image: CGImage) {
        model.image = image
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        still = nil
        composer = nil
        region = nil
        model.image = nil
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        colorObserver = nil
    }

    private func recolor() {
        if let still { setStill(still) }
    }

    private func setStill(_ image: CGImage) {
        still = image
        let made = RecordingFrameComposer(sourceWidth: image.width, sourceHeight: image.height,
                                          color: RecordingFrameStyle.color())
        composer = made
        model.aspect = CGFloat(made.outputHeight) / CGFloat(made.outputWidth)
        model.image = made.framedImage(from: image)
        place()
    }

    private func place() {
        guard let panel, let region else { return }
        let width: CGFloat = 300
        let height = (width * model.aspect).rounded()
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? region
        var x = region.maxX + 16
        if x + width > visible.maxX { x = max(visible.minX, region.minX - width - 16) }
        let y = max(visible.minY, min(region.maxY - height, visible.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// The region as a still, excluding all of this app's windows.
    @available(macOS 15.0, *)
    private static func still(of region: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let bundle = Bundle.main.bundleIdentifier
        let cg = cgRect(from: region)
        guard let display = content.displays.first(where: { $0.frame.intersects(cg) }) ?? content.displays.first else {
            throw AgentError("NOT_FOUND", "Display is no longer available.")
        }
        let filter = SCContentFilter(display: display,
                                     excludingWindows: content.windows.filter { $0.owningApplication?.bundleIdentifier == bundle })
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = CGRect(x: cg.minX - display.frame.minX, y: cg.minY - display.frame.minY,
                                   width: cg.width, height: cg.height)
        config.width = max(2, Int(cg.width * scale) & ~1)
        config.height = max(2, Int(cg.height * scale) & ~1)
        config.captureResolution = .best
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// AppKit global rect (bottom-left origin) → CG global (top-left).
    private static func cgRect(from appKitRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: appKitRect.minX, y: primaryHeight - appKitRect.maxY,
                      width: appKitRect.width, height: appKitRect.height)
    }
}

private struct FramePreviewView: View {
    @ObservedObject var model: FramePreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.25)
            }
            Text("What's saved")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}
