import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private var windows: [NSWindow] = []
    private let onSaved: (NSImage, URL) -> Void

    init(onSaved: @escaping (NSImage, URL) -> Void = { _, _ in }) {
        self.onSaved = onSaved
    }

    func open(image: NSImage, fileURL: URL) {
        let model = EditorModel(image: image, fileURL: fileURL)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.representedURL = fileURL
        window.titleVisibility = .hidden
        // Never movable-by-background here: canvas drags ARE the annotation
        // gestures. The (transparent) title bar region still moves the window.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        let view = EditorView(model: model, onDone: { [weak self, weak window] in
            if let window { self?.close(window) }
        }, onSaved: onSaved)
        let host = NSHostingView(rootView: view)
        // The resizable window owns its bounds. Reflowing the toolbar must
        // not turn a narrow fitting-size query into a taller window minimum.
        host.sizingOptions = []
        window.contentView = host

        let target = idealSize(for: image.size)
        window.setContentSize(target)
        // The toolbar wraps at narrower widths; keep room for its action
        // group and a useful canvas without shrinking any hit targets.
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.center()
        windows.append(window)

        Analytics.track("editor_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 === window }
    }

    private func idealSize(for imageSize: CGSize) -> CGSize {
        let maxSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let toolbarHeight: CGFloat = 2 * 30 + MM.Layout.spacing / 2 + MM.Layout.spacing
        let chrome: CGFloat = 40
        let scale = min(
            (maxSize.width * 0.8) / imageSize.width,
            (maxSize.height * 0.8 - toolbarHeight) / imageSize.height,
            1
        )
        return CGSize(
            width: max(720, imageSize.width * scale + chrome),
            height: max(480, imageSize.height * scale + toolbarHeight + chrome)
        )
    }
}
