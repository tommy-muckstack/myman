import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor final class CaptureChooser {
    static let shared = CaptureChooser()
    private var window: NSWindow?
    func open() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "My Man · Choose capture"; w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.contentView = NSHostingView(rootView: CaptureChooserView(close: { [weak self] in self?.window?.orderOut(nil) }))
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
private struct CaptureChooserView: View {
    var close: () -> Void
    @State private var windows: [SCWindow] = []
    @State private var target = "region"
    @State private var scrolling = false
    @State private var x = "0"
    @State private var y = "0"
    @State private var width = "800"
    @State private var height = "600"
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Choose a window or screen area").font(MM.Fonts.title)
            Picker("Capture target", selection: $target) {
                Text("Screen area").tag("region")
                ForEach(windows, id: \.windowID) { window in Text("\(window.owningApplication?.applicationName ?? "App") · \(window.title ?? "Window")").tag(String(window.windowID)) }
            }.clickable()
            if target == "region" {
                Picker("Use display bounds", selection: Binding(get: { "" }, set: { value in if let i = Int(value), NSScreen.screens.indices.contains(i) { let r = NSScreen.screens[i].frame; x = String(Int(r.minX)); y = String(Int(r.minY)); width = String(Int(r.width)); height = String(Int(r.height)) } })) {
                    Text("Choose a display").tag("")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, screen in Text(screen.localizedName).tag(String(i)) }
                }.clickable()
                Text("Coordinates use points from the lower-left corner of the main display. Adjust the area to exclude fixed headers when scrolling.").font(MM.Fonts.secondary)
                HStack { field("Left", $x); field("Bottom", $y); field("Width", $width); field("Height", $height) }
                Toggle("Join sections as I scroll downward", isOn: $scrolling).clickable()
            }
            HStack {
                Button("Capture") { Task { await capture() } }.disabled(busy).keyboardShortcut(.defaultAction).clickable()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).clickable()
            }
            Text(message).font(MM.Fonts.secondary)
        }.padding(MM.Layout.paddingLarge) }.font(MM.Fonts.body).foregroundStyle(MM.Colors.textPrimary).background(MM.Colors.background)
            .task {
                guard await CaptureEngine.shared.authorizeInteractively() else { message = "Allow Screen Recording in System Settings, then reopen this chooser."; return }
                windows = ((try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows) ?? []).filter { $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 40 && $0.frame.height > 40 }
            }
    }
    private func field(_ label: String, _ value: Binding<String>) -> some View { VStack(alignment: .leading) { Text(label).font(MM.Fonts.metadata); TextField(label, text: value).textFieldStyle(.roundedBorder).accessibilityLabel(label) } }
    private func capture() async {
        busy = true; defer { busy = false }
        do {
            if target != "region" {
                close()
                let (image, _) = try await CaptureEngine.shared.captureWindowForAgent(id: target)
                try save(image)
            } else {
                guard let x = Double(x), let y = Double(y), let w = Double(width), let h = Double(height), [x, y, w, h].allSatisfy(\.isFinite), w >= 20, h >= 20, w <= 8000, h <= 8000 else { throw AgentError("INVALID_ARGUMENTS", "Enter a valid capture area.") }
                let rect = CGRect(x: x, y: y, width: w, height: h)
                close()
                if scrolling { _ = try ScrollingCapture.shared.start(region: rect, human: true) }
                else { guard let image = try await CaptureEngine.shared.captureAllDisplaysComposite().crop(to: rect) else { throw AgentError("INVALID_ARGUMENTS", "This area is outside the displays.") }; try save(image) }
            }
        } catch { message = error.localizedDescription; Toast.show(message) }
    }
    private func save(_ image: NSImage) throws {
        let result = try CaptureController().saveAgentImage(image, capturedAt: Date(), meetingID: nil, clipboard: true)
        if let id = result["id"] as? String, let item = CaptureIndex.item(id) { CaptureActions.open(item) }
    }
}
