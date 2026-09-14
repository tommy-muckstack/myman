import AppKit
import GRDB
import SwiftUI

struct Screenshot: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "screenshot"
    var id: String
    var path: String
    var ocrText: String
    var createdAt: Date
}

/// Region capture end to end: freeze all displays → selection overlay → crop →
/// save (file + clipboard) → OCR into the shared index → floating thumbnail.
@MainActor
final class CaptureController: SelectionOverlayDelegate {
    private var overlay: SelectionOverlayCoordinator?
    private var frozenCapture: CompositeCapture?
    var meetingIDProvider: () -> String? = { nil }
    private var capturedAt = Date()
    private var capturedMeetingID: String?
    private var windowsTask: Task<CaptureWindowSnapshot, Never>?
    private var captureMainDisplayHeight: CGFloat = 0
    private var thumbnail: ThumbnailPanel?
    private lazy var editor = EditorWindowController { [weak self] image, fileURL in
        self?.showThumbnail(image: image, fileURL: fileURL)
    }

    static var saveFolder: URL {
        SettingsStore.shared.screenshotFolderURL
    }

    func beginRegionCapture() {
        if NSWorkspace.shared.isVoiceOverEnabled { CaptureChooser.shared.open(); return }
        guard overlay?.isShowing != true else { return }
        Task { @MainActor in
            let engine = CaptureEngine.shared
            guard await engine.authorizeInteractively() else {
                showPermissionAlert()
                return
            }

            // Freeze the screen first, then select on top of the frozen image.
            capturedAt = Date(); capturedMeetingID = meetingIDProvider()
            captureMainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
            windowsTask = Task.detached(priority: .utility) { CaptureWindowSnapshot.take() }
            let frozen = try? await engine.captureAllDisplaysComposite()
            frozenCapture = frozen
            // Recreate per capture — screens may have changed since last time.
            overlay = SelectionOverlayCoordinator(frozenCapture: frozen)
            overlay?.delegate = self
            // Do NOT activate My Man here. Activating a menu-bar app just
            // before a non-activating selection overlay causes AppKit to eat
            // the user's first selection click as an app-activation click.
            // The overlay windows are explicitly allowed to receive input
            // without focus stealing (see SelectionOverlayWindow).
            overlay?.showAll()
        }
    }

    /// Explicit agent capture uses the same save/OCR/context pipeline as the overlay.
    func captureForAgent(region: CGRect, clipboard: Bool) async throws -> [String: Any] {
        let date = Date(), meetingID = meetingIDProvider()
        let (image, scale) = try await imageForAgent(region: region)
        var result = try saveAgentImage(image, capturedAt: date, meetingID: meetingID, clipboard: clipboard)
        result["scale"] = scale
        await saveAgentContext(id: result["id"] as! String, region: region, meetingID: meetingID)
        return result
    }
    func imageForAgent(region: CGRect) async throws -> (NSImage, Double) {
        guard overlay?.isShowing != true else { throw AgentError("BUSY", "Finish the current screenshot selection first.") }
        guard await CaptureEngine.shared.authorizeInteractively() else { throw AgentError("PERMISSION_REQUIRED", "Grant My Man Screen Recording access in System Settings.") }
        let frozen = try await CaptureEngine.shared.captureAllDisplaysComposite()
        guard frozen.combinedFrame.contains(region), let image = frozen.crop(to: region) else { throw AgentError("INVALID_ARGUMENTS", "Region must fit within the captured desktop.") }
        return (image, frozen.scaleFactor)
    }
    func saveAgentContext(id: String, region: CGRect, meetingID: String?) async {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let snapshot = await Task.detached(priority: .utility) { CaptureWindowSnapshot.take() }.value
        if let window = snapshot.selected(in: region, mainDisplayHeight: mainHeight) {
            let origin = ScreenshotContext(itemID: id, timezone: TimeZone.current.identifier, meetingID: meetingID, app: window.app, bundleID: window.bundleID, windowTitle: window.title, url: window.url)
            try? await Database.shared.write { try ScreenshotContext.saveOrigin(origin, in: $0, metadataEnabled: UserDefaults.standard.bool(forKey: "captureWindowMetadata"), excludedApps: UserDefaults.standard.string(forKey: "captureMetadataExcludedApps") ?? "") }
        }
    }

    func saveAgentImage(_ image: NSImage, capturedAt: Date = Date(), meetingID: String? = nil, clipboard: Bool = false) throws -> [String: Any] {
        let png = try AgentImages.png(image)
        let id = UUID().uuidString
        let url = Self.saveFolder.appendingPathComponent("My Man \(id).png")
        try FileManager.default.createDirectory(at: Self.saveFolder, withIntermediateDirectories: true)
        try png.write(to: url, options: .withoutOverwriting)
        do {
            try Database.shared.write { db in
                try Screenshot(id: id, path: url.path, ocrText: "", createdAt: capturedAt).insert(db)
                try ScreenshotContext.saveOrigin(ScreenshotContext(itemID: "shot-" + id, timezone: TimeZone.current.identifier, meetingID: meetingID), in: db)
            }
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        OCRStore.refresh(image: image, fileURL: url, id: id)
        if clipboard { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png) }
        return ["id": "shot-" + id, "kind": "screenshot", "path": url.path, "image_path": url.path, "created_at": AgentActions.date(capturedAt), "timezone": TimeZone.current.identifier, "brain_path": Brain.screenshotFilePath(id: id, createdAt: capturedAt), "width": AgentImages.size(image).width, "height": AgentImages.size(image).height, "ocr_status": "processing"]
    }

    /// Open an existing capture (e.g. from launcher search) in the editor.
    func openInEditor(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else {
            // Ghost row (early builds had a filename bug) — drop it and say so.
            if let items = try? Database.shared.read({ try CaptureItem.fetchAll($0, sql: "SELECT * FROM captureItem WHERE kind = 'screenshot' AND sourcePath = ?", arguments: [fileURL.path]) }) {
                for item in items { CaptureActions.perform { try CaptureLifecycle.delete(item) } }
            }
            Toast.show("That screenshot's file is missing — removed it from search",
                       systemImage: "exclamationmark.triangle")
            return
        }
        editor.open(image: image, fileURL: fileURL)
    }

    // MARK: SelectionOverlayDelegate

    func selectionOverlayDidComplete(with rect: CGRect) {
        overlay?.hideAll()
        overlay = nil
        guard let cropped = frozenCapture?.crop(to: rect) else { return }
        frozenCapture = nil
        save(cropped, rect: rect)
    }

    func selectionOverlayDidCancel() {
        overlay?.hideAll()
        overlay = nil
        frozenCapture = nil
        windowsTask?.cancel(); windowsTask = nil
    }

    // MARK: Save pipeline

    private func save(_ image: NSImage, rect: CGRect) {
        let result: [String: Any]
        do { result = try saveAgentImage(image, capturedAt: capturedAt, meetingID: capturedMeetingID, clipboard: true) }
        catch { Toast.show("Couldn't save the screenshot file", systemImage: "exclamationmark.triangle"); return }
        let url = URL(fileURLWithPath: result["path"] as! String)
        var origin = ScreenshotContext(itemID: result["id"] as! String, timezone: TimeZone.current.identifier, meetingID: capturedMeetingID)
        let windowTask = windowsTask, displayHeight = captureMainDisplayHeight
        windowsTask = nil
        Task {
            if let snapshot = await windowTask?.value,
               UserDefaults.standard.bool(forKey: "captureWindowMetadata"),
               let window = snapshot.selected(in: rect, mainDisplayHeight: displayHeight) {
                let excluded = (UserDefaults.standard.string(forKey: "captureMetadataExcludedApps") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !excluded.contains(window.app.lowercased()) && !excluded.contains(window.bundleID.lowercased()) {
                    origin.app = window.app; origin.bundleID = window.bundleID
                    origin.windowTitle = window.title; origin.url = window.url
                    try? await Database.shared.write { [origin] in try ScreenshotContext.saveOrigin(origin, in: $0, metadataEnabled: UserDefaults.standard.bool(forKey: "captureWindowMetadata"), excludedApps: UserDefaults.standard.string(forKey: "captureMetadataExcludedApps") ?? "") }
                }
            }
        }

        Analytics.track("screenshot_captured")
        showThumbnail(image: image, fileURL: url)
    }

    private func showThumbnail(image: NSImage, fileURL: URL) {
        thumbnail?.close()
        thumbnail = ThumbnailPanel(
            image: image,
            fileURL: fileURL,
            onEdit: { [weak self] in
                self?.thumbnail?.close()
                self?.editor.open(image: image, fileURL: fileURL)
            },
            onClose: { [weak self] in
                self?.thumbnail = nil
            }
        )
        thumbnail?.show()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "My Man needs Screen Recording access"
        alert.informativeText = "Grant it in System Settings → Privacy & Security → Screen Recording, then relaunch My Man.\n\nAlready toggled on but still seeing this? macOS has the grant bound to an old copy of the app: remove My Man from that list with the − button, relaunch My Man, and grant the fresh prompt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The post-capture pill: a floating preview in the bottom-LEFT. Hovering
/// holds it open and reveals actions; clicking it opens the editor; it can be
/// dragged into any app; left alone, it quietly disappears.
/// Drives the preview's visible countdown; nil while hovering (paused).
@MainActor
final class ThumbnailCountdownModel: ObservableObject {
    @Published var cycle: (duration: TimeInterval, id: UUID)?
}

@MainActor
final class ThumbnailPanel {
    private let panel: NSPanel
    private var dismissTimer: Timer?
    private let onClose: () -> Void
    private var closed = false
    private let countdown = ThumbnailCountdownModel()

    init(image: NSImage, fileURL: URL,
         onEdit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        let view = ThumbnailView(
            image: image,
            fileURL: fileURL,
            countdown: countdown,
            onEdit: onEdit,
            onDismiss: { [weak self] in self?.close() },
            onHoverChanged: { [weak self] hovering in
                // Hovering means "I'm not done with this" — hold it open.
                if hovering {
                    self?.dismissTimer?.invalidate()
                    self?.dismissTimer = nil
                    self?.countdown.cycle = nil
                } else {
                    // Fresh countdown every time the cursor leaves.
                    self?.scheduleDismiss(after: 5)
                }
            }
        )
        let hosting = NSHostingView(rootView: view)
        // Same rule as FloatingPanel: content never sizes the window via
        // autolayout (the thumbnail grows on hover — reentrant-resize bait).
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? .zero
        let size = (fitting.width > 1 && fitting.height > 1) ? fitting : NSSize(width: 320, height: 240)
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: visible.minX + 20,
                y: visible.minY + 20,
                width: size.width, height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()
        scheduleDismiss(after: 10)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        guard !NSWorkspace.shared.isVoiceOverEnabled else { countdown.cycle = nil; return }
        countdown.cycle = (seconds, UUID())
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
        onClose()
    }
}

private struct ThumbnailView: View {
    let image: NSImage
    let fileURL: URL
    @ObservedObject var countdown: ThumbnailCountdownModel
    var onEdit: () -> Void
    var onDismiss: () -> Void
    var onHoverChanged: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
                .overlay(hoverActions, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    if let cycle = countdown.cycle, !hovering {
                        CountdownBar(duration: cycle.duration, color: .white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                            .id(cycle.id)
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)

            dismissButton
        }
        .padding(8)
        .animation(MM.Motion.gentle, value: hovering)
        .onHover { h in
            hovering = h
            onHoverChanged(h)
        }
        .onTapGesture { onEdit() }
        .accessibilityAction(named: Text("Edit screenshot"), onEdit)
        .draggable(fileURL)
        .help("Copied to clipboard — click to edit, drag anywhere")
    }

    private var hoverActions: some View {
        HStack(spacing: 14) {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }.buttonStyle(.plain).clickable()
            Button {
                CaptureActions.perform {
                    if let item = try Database.shared.read({ try CaptureItem.fetchOne($0, sql: "SELECT * FROM captureItem WHERE sourcePath = ?", arguments: [fileURL.path]) }) { try FloatingReference.open(item); onDismiss() }
                }
            } label: { Label("Float", systemImage: "pin") }.buttonStyle(.plain).clickable()
            Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    onDismiss()
            } label: { Label("Finder", systemImage: "folder") }.buttonStyle(.plain).clickable()
        }
        .font(MM.Fonts.hint)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.65)))
        .padding(.bottom, 8)
        .opacity(1)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) { Image(systemName: "xmark.circle.fill")
            .font(.system(size: 15))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.6))
        }.buttonStyle(.plain).accessibilityLabel("Dismiss screenshot preview").clickable(minSize: 32)
    }
}
