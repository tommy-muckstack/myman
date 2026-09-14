import AppKit
import SwiftUI
import Combine

@MainActor final class ScrollingCapture: ObservableObject, SelectionOverlayDelegate {
    static let shared = ScrollingCapture()
    @Published private(set) var sessionID: String?
    @Published private(set) var state = "idle"
    @Published private(set) var message = ""
    @Published private(set) var sections = 0
    private var owner = "human"
    private var region = CGRect.zero
    private var previous: CGImage?
    private var composite: CGImage?
    private var task: Task<Void, Never>?
    private var overlay: SelectionOverlayCoordinator?
    private var panel: NSPanel?
    private var capturing = false
    private let capture = CaptureController()
    func beginSelection() {
        guard sessionID == nil else { showPanel(); return }
        Task {
            guard await CaptureEngine.shared.authorizeInteractively() else { Toast.show("Screen Recording permission is required."); return }
            let frozen = try? await CaptureEngine.shared.captureAllDisplaysComposite()
            overlay = SelectionOverlayCoordinator(frozenCapture: frozen); overlay?.delegate = self; overlay?.showAll()
        }
    }
    func selectionOverlayDidComplete(with rect: CGRect) {
        overlay?.hideAll(); overlay = nil
        do { _ = try start(region: rect, human: true) } catch { Toast.show(error.localizedDescription) }
    }
    func selectionOverlayDidCancel() { overlay?.hideAll(); overlay = nil }
    @discardableResult func start(region: CGRect, human: Bool = false) throws -> String {
        guard CGPreflightScreenCaptureAccess() else { throw AgentError("PERMISSION_REQUIRED", "Allow Screen Recording for My Man in System Settings.") }
        guard sessionID == nil else { throw AgentError("BUSY", "Finish the current scrolling capture first.") }
        guard region.width >= 100, region.height >= 100, region.width <= 8000, region.height <= 8000, [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite) else { throw AgentError("INVALID_ARGUMENTS", "Select a scrollable area at least 100 × 100 points.") }
        self.region = region; owner = human ? "human" : AgentContext.principal.id
        sessionID = UUID().uuidString; state = "capturing"; sections = 0
        message = "Scroll downward slowly, keeping some of the previous section visible. Exclude fixed headers from the selected area."
        showPanel()
        task = Task { while !Task.isCancelled, state == "capturing" { await sample(); try? await Task.sleep(for: .milliseconds(900)) } }
        return sessionID!
    }
    func status(id: String, human: Bool = false) throws -> [String: Any] {
        try check(id, human: human)
        return ["session_id": id, "state": state, "sections": sections, "message": message]
    }
    private func check(_ id: String, human: Bool) throws {
        guard sessionID == id else { throw AgentError("SESSION_MISMATCH", "This scrolling capture is no longer active.") }
        guard human || owner == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "This scrolling capture belongs to someone else.") }
    }
    private func sample() async {
        guard !capturing, let generation = sessionID else { return }; capturing = true
        panel?.orderOut(nil)
        defer { capturing = false; if sessionID != nil { panel?.orderFrontRegardless() } }
        do {
            let image = try await CaptureEngine.shared.captureAllDisplaysComposite().crop(to: region)
            guard sessionID == generation, state == "capturing" else { return }
            guard let image, let next = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AgentError("CAPTURE_FAILED", "The selected area is outside the current displays.") }
            guard next.height <= 20000, next.width * next.height <= 40_000_000 else { throw AgentError("TOO_LARGE", "Select a smaller capture area.") }
            if let previous, let composite {
                let result = try await Task.detached(priority: .userInitiated) { try ScrollStitcher.append(previous: previous, next: next, composite: composite) }.value
                guard sessionID == generation, state == "capturing" else { return }
                switch result {
                case .unchanged: break
                case .noOverlap: message = "Could not match this section. Scroll back a little, move more slowly, or save and select an area without fixed headers."
                case .appended(let combined, _): self.composite = combined; self.previous = next; sections += 1; message = "\(sections) sections joined. Keep scrolling, or save."
                }
            } else { previous = next; composite = next; sections = 1 }
        } catch { if sessionID == generation { message = error.localizedDescription; state = "paused" } }
    }
    func finish(id: String, human: Bool = false) async throws -> [String: Any] {
        try check(id, human: human)
        state = "saving"; task?.cancel()
        while capturing { try? await Task.sleep(for: .milliseconds(25)) }
        try check(id, human: human)
        guard let composite else { state = "paused"; throw AgentError("CAPTURE_FAILED", "No section has been captured yet.") }
        do {
            let result = try capture.saveAgentImage(NSImage(cgImage: composite, size: NSSize(width: composite.width, height: composite.height)), capturedAt: Date(), meetingID: nil, clipboard: human)
            clear(); return result
        } catch { state = "paused"; throw error }
    }
    func cancel(id: String, human: Bool = false) throws { try check(id, human: human); clear() }
    private func clear() { task?.cancel(); task = nil; sessionID = nil; previous = nil; composite = nil; state = "idle"; panel?.close(); panel = nil }
    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 230), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "My Man · Scrolling capture"; panel.isReleasedWhenClosed = false; panel.level = .floating
            panel.contentView = NSHostingView(rootView: ScrollingCaptureControls(controller: self)); panel.center(); self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

private struct ScrollingCaptureControls: View {
    @ObservedObject var controller: ScrollingCapture
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Scrolling capture · \(controller.sections) sections").font(MM.Fonts.title)
            Text(controller.message).font(MM.Fonts.secondary)
            HStack {
                Button("Save capture") { guard let id = controller.sessionID else { return }; saving = true; Task { do { let value = try await controller.finish(id: id, human: true); if let id = value["id"] as? String, let item = CaptureIndex.item(id) { CaptureActions.open(item) } } catch { Toast.show(error.localizedDescription) }; saving = false } }.disabled(saving || controller.sections == 0).clickable()
                Button("Cancel") { if let id = controller.sessionID { try? controller.cancel(id: id, human: true) } }.disabled(saving).clickable()
            }
        }.padding(MM.Layout.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(MM.Colors.background).foregroundStyle(MM.Colors.textPrimary)
    }
}
