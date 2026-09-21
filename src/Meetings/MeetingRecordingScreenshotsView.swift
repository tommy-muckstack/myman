import AppKit
import SwiftUI

struct MeetingRecordingScreenshotsView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var capture: MeetingSlideCapture
    var onSeek: (TimeInterval) -> Void
    @State private var selectedPath: String?

    init(controller: MeetingController, onSeek: @escaping (TimeInterval) -> Void) {
        self.controller = controller
        self.capture = controller.slideCapture
        self.onSeek = onSeek
    }

    private var selected: MeetingSlide? {
        capture.slides.first { $0.path == selectedPath } ?? capture.slides.last
    }
    private var index: Int { capture.slides.firstIndex { $0.path == selected?.path } ?? 0 }

    var body: some View {
        VStack(spacing: MM.Layout.spacing / 2) {
            HStack {
                Text("Screenshots from this call")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                Spacer()
                Button {
                    Task { if let slide = await controller.captureSharedScreen() { selectedPath = slide.path } }
                } label: {
                    Label(capture.busy ? "Capturing…" : "Capture screen", systemImage: "camera")
                        .font(MM.Fonts.metadata).clickable(minSize: 28)
                }
                .buttonStyle(.plain).foregroundStyle(MM.Colors.accent)
                .disabled(capture.busy || controller.activeCaptureMeetingID == nil)
                .help("Capture the visible call window, including a shared screen")
            }
            if let selected {
                MeetingRecordingScreenshotImage(path: selected.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: MM.Layout.spacing / 2) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").clickable(minSize: 28) }
                        .disabled(index == 0).accessibilityLabel("Previous screenshot")
                    Text("\(index + 1) of \(capture.slides.count)").font(MM.Fonts.metadata)
                    Button { move(1) } label: { Image(systemName: "chevron.right").clickable(minSize: 28) }
                        .disabled(index + 1 >= capture.slides.count).accessibilityLabel("Next screenshot")
                    Spacer(minLength: 0)
                    Button { if let offset = selected.offset { onSeek(offset) } } label: {
                        Text(selected.timestamp).font(MM.Fonts.metadata).clickable(minSize: 28)
                    }
                    .foregroundStyle(MM.Colors.accent)
                    .disabled(selected.offset == nil)
                    .help("Show this point in the transcript")
                    Button(role: .destructive) {
                        let before = capture.slides
                        let oldIndex = index
                        controller.removeRecordingScreenshot(selected.path)
                        if capture.slides != before {
                            selectedPath = capture.slides.isEmpty ? nil : capture.slides[min(oldIndex, capture.slides.count - 1)].path
                        }
                    } label: { Image(systemName: "trash").clickable(minSize: 28) }
                    .accessibilityLabel("Delete screenshot")
                    .help("Move this screenshot to Trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(MM.Colors.textSecondary)
                Text(selected.automatic ? "Automatically captured" : "Captured by you")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            } else {
                UtilityEmptyState(icon: .screenshot, title: "Screenshots from your call",
                                  message: "Automatic captures appear here. You can also capture the visible shared screen.", compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = controller.screenshotMessage {
                Text(message).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
        }
        .onAppear { selectedPath = capture.slides.last?.path }
        .onChange(of: capture.paths) { old, new in
            // Follow new images only while viewing the latest. Browsing an
            // earlier screenshot must not be interrupted by a timer capture.
            if selectedPath == nil || selectedPath == old.last { selectedPath = new.last }
        }
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard capture.slides.indices.contains(next) else { return }
        selectedPath = capture.slides[next].path
    }
}

private struct MeetingRecordingScreenshotImage: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .contextMenu {
                        Button("Copy") {
                            if let original = NSImage(contentsOfFile: path) { CaptureActions.copyImage(original) }
                        }
                        Button("Open image") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
            } else {
                Text("Preview unavailable").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .task(id: path) {
            image = nil
            let loaded = await Task.detached(priority: .utility) { CaptureThumbnailCache.load(path: path, size: 1600) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
