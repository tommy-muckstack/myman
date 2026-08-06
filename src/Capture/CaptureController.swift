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
    private var thumbnail: ThumbnailPanel?
    private lazy var editor = EditorWindowController { [weak self] image, fileURL in
        self?.showThumbnail(image: image, fileURL: fileURL)
    }

    static var saveFolder: URL {
        SettingsStore.shared.screenshotFolderURL
    }

    func beginRegionCapture() {
        guard overlay?.isShowing != true else { return }
        Task { @MainActor in
            let engine = CaptureEngine.shared
            guard await engine.authorizeInteractively() else {
                showPermissionAlert()
                return
            }

            // Freeze the screen first, then select on top of the frozen image.
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

    /// Open an existing capture (e.g. from launcher search) in the editor.
    func openInEditor(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else {
            // Ghost row (early builds had a filename bug) — drop it and say so.
            try? Database.shared.write { db in
                try db.execute(sql: "DELETE FROM screenshot WHERE path = ?",
                               arguments: [fileURL.path])
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
        save(cropped)
    }

    func selectionOverlayDidCancel() {
        overlay?.hideAll()
        overlay = nil
        frozenCapture = nil
    }

    // MARK: Save pipeline

    private func save(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [.compressionFactor: 1.0])
        else { return }

        let folder = Self.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Fixed format — a localized date once produced "08/5/2026" and the
        // slashes made every write silently fail.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("My Man \(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
        } catch {
            NSLog("My Man [Capture] save failed: \(error)")
            Toast.show("Couldn't save the screenshot file", systemImage: "exclamationmark.triangle")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let record = Screenshot(id: UUID().uuidString, path: url.path, ocrText: "", createdAt: Date())
        try? Database.shared.write { try record.insert($0) }

        // OCR off the critical path; the index catches up seconds later.
        Task.detached(priority: .utility) { [record] in
            let analysis = await ImageAnalysis.analyze(image)
            let updated = Screenshot(
                id: record.id, path: record.path,
                ocrText: analysis.searchableText, createdAt: record.createdAt
            )
            try? await Database.shared.write { try updated.update($0) }
            Brain.syncScreenshot(id: record.id, filePath: record.path,
                                 ocrText: analysis.searchableText,
                                 createdAt: record.createdAt)
            if let blob = SearchService.embedding(for: analysis.searchableText) {
                try? await Database.shared.write { db in
                    try db.execute(sql: "UPDATE screenshot SET embedding = ? WHERE id = ?",
                                   arguments: [blob, record.id])
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
        .draggable(fileURL)
        .help("Copied to clipboard — click to edit, drag anywhere")
    }

    private var hoverActions: some View {
        HStack(spacing: 14) {
            Label("Edit", systemImage: "pencil")
                .clickable(minSize: 22)
                .onTapGesture { onEdit() }
            Label("Finder", systemImage: "folder")
                .clickable(minSize: 22)
                .onTapGesture {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    onDismiss()
                }
        }
        .font(MM.Fonts.hint)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.65)))
        .padding(.bottom, 8)
        .opacity(hovering ? 1 : 0)
    }

    private var dismissButton: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 15))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.6))
            .clickable(minSize: 32)
            .onTapGesture { onDismiss() }
            .opacity(hovering ? 1 : 0)
    }
}
