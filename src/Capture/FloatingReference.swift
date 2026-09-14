import AppKit
import SwiftUI

@MainActor enum FloatingReference {
    private static var windows: [String: NSWindow] = [:]
    private static var observers: [String: NSObjectProtocol] = [:]
    static func open(_ item: CaptureItem) throws {
        guard item.kind == "screenshot", !item.excluded, let image = NSImage(contentsOfFile: item.sourcePath) else { throw AgentError("NOT_FOUND", "Choose an available screenshot.") }
        if let window = windows[item.id] { window.makeKeyAndOrderFront(nil); return }
        guard windows.count < 8 else { throw AgentError("TOO_MANY_WINDOWS", "Close a floating reference before opening another.") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 400, height: 220)
        window.title = "My Man · " + item.title; window.isReleasedWhenClosed = false; window.level = .floating
        window.contentView = NSHostingView(rootView: FloatingReferenceView(image: image, path: item.sourcePath, window: window))
        windows[item.id] = window
        observers[item.id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated {
            windows[item.id] = nil
            if let token = observers.removeValue(forKey: item.id) { NotificationCenter.default.removeObserver(token) }
        } }
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    static func purge(itemID: String?) {
        for id in Array(windows.keys) where itemID == nil || itemID == id { windows[id]?.close(); windows[id] = nil }
    }
}
private struct FloatingReferenceView: View {
    let image: NSImage
    let path: String
    let window: NSWindow
    @State private var opacity = 1.0
    var body: some View {
        VStack {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Floating screenshot reference").draggable(URL(fileURLWithPath: path))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }.clickable()
                Slider(value: $opacity, in: 0.3...1) { Text("Window opacity") }.onChange(of: opacity) { _, value in window.alphaValue = value }
                Button("Close") { window.close() }.clickable()
            }.font(MM.Fonts.secondary)
        }.padding(MM.Layout.spacing).background(MM.Colors.background).foregroundStyle(MM.Colors.textPrimary)
    }
}
