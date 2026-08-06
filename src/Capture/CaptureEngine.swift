import AppKit
import ScreenCaptureKit

/// A composite screenshot of all displays plus the exact geometry used to
/// build it. Consumers that crop the composite MUST use this geometry instead
/// of recomputing it from NSScreen — the display sets can disagree during
/// clamshell/hotplug transitions, which shifts every crop.
struct CompositeCapture {
    let image: NSImage
    /// Bounding rect of all captured displays, points, bottom-left origin.
    let combinedFrame: CGRect
    /// The scale factor the composite was rendered at (max of all displays).
    let scaleFactor: CGFloat

    /// Crop a region (virtual-desktop points, bottom-left origin) out of the
    /// composite. Clamps to the image bounds so edge-of-screen selections
    /// survive float rounding; nil only if the region misses entirely.
    func crop(to rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let relativeX = rect.origin.x - combinedFrame.origin.x
        // Flip Y: bottom-left virtual desktop → top-left image coords
        let distanceFromTop = (combinedFrame.origin.y + combinedFrame.height) - (rect.origin.y + rect.height)
        let pixelRect = CGRect(
            x: relativeX * scaleFactor,
            y: distanceFromTop * scaleFactor,
            width: rect.width * scaleFactor,
            height: rect.height * scaleFactor
        )
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isEmpty, let cropped = cgImage.cropping(to: clamped) else { return nil }
        return NSImage(
            cgImage: cropped,
            size: CGSize(width: clamped.width / scaleFactor, height: clamped.height / scaleFactor)
        )
    }
}

@MainActor
final class CaptureEngine: ObservableObject {
    static let shared = CaptureEngine()

    @Published private(set) var isAuthorized = false

    enum CaptureError: Error {
        case noDisplayFound
        case captureFailure
    }

    private init() {
        Task { await checkAuthorization() }
    }

    /// Passive check — never triggers a system prompt. The preflight gates the
    /// SCShareableContent probe because probing while undetermined shows the
    /// system dialog on its own.
    func checkAuthorization() async {
        guard CGPreflightScreenCaptureAccess() else {
            isAuthorized = false
            return
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
    }

    /// Shows the system prompt (first call per launch only — macOS ignores
    /// repeat calls). Drive this from explicit user action.
    func requestPermission() async {
        if CGRequestScreenCaptureAccess() {
            await checkAuthorization()
        } else {
            isAuthorized = false
        }
    }

    /// For explicit capture attempts: trust the real capability, not the
    /// preflight — CGPreflight can go stale (grants bound to a defunct copy,
    /// mid-session grants). Probing may show the system prompt, which is
    /// exactly right when the user just hit the screenshot hotkey.
    func authorizeInteractively() async -> Bool {
        if (try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)) != nil {
            isAuthorized = true
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        if (try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)) != nil {
            isAuthorized = true
            return true
        }
        isAuthorized = false
        return false
    }

    /// Capture all displays composited into one image, returned together with
    /// the geometry it was rendered with so downstream crops can't drift.
    func captureAllDisplaysComposite() async throws -> CompositeCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = DisplayLayout.allDisplays(from: content)
        guard !displays.isEmpty else { throw CaptureError.noDisplayFound }

        let combinedFrame = DisplayLayout.combinedFrame(of: displays)
        // Use the max scale factor of ALL displays — must match the scale the
        // crop math assumes, or selections on lower-DPI displays land wrong.
        let maxScale = displays.map(\.scaleFactor).max() ?? 2.0

        var captured: [(CGImage, DisplayInfo)] = []
        for display in displays {
            let filter = SCContentFilter(display: display.scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.pixelWidth
            config.height = display.pixelHeight
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            captured.append((image, display))
        }

        let pixelWidth = Int(combinedFrame.width * maxScale)
        let pixelHeight = Int(combinedFrame.height * maxScale)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw CaptureError.captureFailure }

        // Transparent base handles gaps between monitors.
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        for (image, display) in captured {
            let relativeX = (display.frame.origin.x - combinedFrame.origin.x) * maxScale
            // Flip: distance from the combined frame's top to this display's top.
            let distanceFromTop = (combinedFrame.origin.y + combinedFrame.height)
                - (display.frame.origin.y + display.frame.height)
            let relativeY = distanceFromTop * maxScale
            // Each display captures at its own scale; normalize into the composite's.
            let ratio = maxScale / display.scaleFactor
            context.draw(image, in: CGRect(
                x: relativeX, y: relativeY,
                width: CGFloat(image.width) * ratio,
                height: CGFloat(image.height) * ratio
            ))
        }

        guard let composite = context.makeImage() else { throw CaptureError.captureFailure }
        return CompositeCapture(
            image: NSImage(cgImage: composite, size: combinedFrame.size),
            combinedFrame: combinedFrame,
            scaleFactor: maxScale
        )
    }
}
