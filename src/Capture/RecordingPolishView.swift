import AppKit
import AVKit
import SwiftUI

/// The Polish window: preview, trim, backdrop, click zooms, Export.
@MainActor
final class RecordingPolishController {
    static let shared = RecordingPolishController()
    private var windows: [String: NSWindow] = [:]

    func open(movie: URL) {
        if let existing = windows[movie.path] { existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 620))
        window.contentMinSize = NSSize(width: 620, height: 480)
        window.center()
        window.contentView = NSHostingView(rootView: RecordingPolishView(movie: movie, onClose: { [weak self, weak window] in
            self?.windows[movie.path] = nil
            window?.close()
        }))
        windows[movie.path] = window
        Analytics.track("recording_polish_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct RecordingPolishView: View {
    let movie: URL
    var onClose: () -> Void
    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var options = PolishOptions()
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var clicks: [RecordedClick] = []
    @State private var cursor: CursorTrack?
    @State private var keystrokes: [RecordedKeystroke] = []
    @State private var exporting = false
    @State private var progress: Double = 0
    @State private var error: String?

    init(movie: URL, onClose: @escaping () -> Void) {
        self.movie = movie
        self.onClose = onClose
        _player = State(initialValue: AVPlayer(url: movie))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Text("Polish recording").font(MM.Fonts.title).foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                Text(movie.deletingPathExtension().lastPathComponent).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).lineLimit(1)
            }
            VideoPlayer(player: player)
                .frame(minHeight: 260)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            section("Trim") {
                HStack(spacing: MM.Layout.spacing) {
                    Text(stamp(trimStart)).font(MM.Fonts.metadata.monospacedDigit()).foregroundStyle(MM.Colors.textSecondary).frame(width: 44)
                    Slider(value: $trimStart, in: 0...max(0.1, duration)) { _ in seek(trimStart) }
                        .onChange(of: trimStart) { _, v in if v > trimEnd - 0.1 { trimStart = max(0, trimEnd - 0.1) } }
                    Slider(value: $trimEnd, in: 0...max(0.1, duration)) { _ in seek(trimEnd) }
                        .onChange(of: trimEnd) { _, v in if v < trimStart + 0.1 { trimEnd = min(duration, trimStart + 0.1) } }
                    Text(stamp(trimEnd)).font(MM.Fonts.metadata.monospacedDigit()).foregroundStyle(MM.Colors.textSecondary).frame(width: 44)
                }
                Text("Keeps \(stamp(max(0, trimEnd - trimStart))) of \(stamp(duration)).").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
            section("Backdrop") {
                Picker("Backdrop", selection: $options.backdrop) {
                    ForEach(BackdropStyle.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            section("Zoom") {
                Toggle(clicks.isEmpty ? "Zoom toward clicks — no clicks were recorded" : "Zoom toward clicks (\(clicks.count) recorded)", isOn: $options.zoomOnClicks)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).disabled(clicks.isEmpty)
                if !clicks.isEmpty, options.zoomOnClicks {
                    HStack(spacing: MM.Layout.spacing) {
                        Text("Amount").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                        Slider(value: Binding(get: { Double(options.zoomScale) }, set: { options.zoomScale = CGFloat($0) }), in: 1.3...2.6)
                        Text(String(format: "%.1f×", options.zoomScale)).font(MM.Fonts.metadata.monospacedDigit()).foregroundStyle(MM.Colors.textSecondary).frame(width: 36)
                    }
                }
            }
            section("Cursor and keys") {
                if let cursor, cursor.separate {
                    Toggle("Draw a smooth cursor", isOn: $options.drawCursor)
                        .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
                    if options.drawCursor {
                        HStack(spacing: MM.Layout.spacing) {
                            Toggle("Smooth movement", isOn: $options.smoothCursor).font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
                            Text("Size").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                            Slider(value: Binding(get: { Double(options.cursorSize) }, set: { options.cursorSize = CGFloat($0) }), in: 1...3)
                            Text(String(format: "%.1f×", options.cursorSize)).font(MM.Fonts.metadata.monospacedDigit()).foregroundStyle(MM.Colors.textSecondary).frame(width: 36)
                        }
                    }
                } else {
                    Text("Cursor smoothing needs “Record the cursor separately” in Settings → Screen Recording before recording.")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
                Toggle(keystrokes.isEmpty ? "Show keyboard shortcuts — none were recorded" : "Show keyboard shortcuts (\(keystrokes.count) recorded)", isOn: $options.showKeystrokes)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).disabled(keystrokes.isEmpty)
                Toggle("Motion blur while zooming", isOn: $options.motionBlur)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).disabled(!options.zoomOnClicks)
            }
            if let error { Text(error).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.danger) }
            HStack {
                Text("The original recording is kept. Export writes a new .mp4 beside it.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                if exporting { ProgressView(value: progress).frame(width: 120).controlSize(.small) }
                Button("Cancel") { player.pause(); onClose() }.keyboardShortcut(.cancelAction).clickable().disabled(exporting)
                Button(exporting ? "Exporting…" : "Export") { export() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(MM.Colors.accent).clickable().disabled(exporting || duration == 0)
            }
        }
        .padding(MM.Layout.paddingLarge)
        .background(MM.Colors.background)
        .task {
            let asset = AVURLAsset(url: movie)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            trimEnd = duration
            clicks = ClickLog.load(for: movie)
            if clicks.isEmpty { options.zoomOnClicks = false }
            cursor = RecordingSidecars.loadCursor(for: movie)
            options.drawCursor = cursor?.separate == true
            keystrokes = RecordingSidecars.loadKeys(for: movie)
            options.showKeystrokes = !keystrokes.isEmpty
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            Text(title).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
            content()
        }
    }

    private func stamp(_ seconds: Double) -> String { MeetingSource.stamp(seconds) }

    private func seek(_ seconds: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func export() {
        exporting = true; progress = 0; error = nil
        player.pause()
        var chosen = options
        chosen.trimStart = trimStart
        chosen.trimEnd = trimEnd
        let destination = RecordingPolish.outputURL(for: movie)
        let source = movie, clicks = clicks, cursor = cursor, keystrokes = keystrokes
        Task { @MainActor in
            do {
                try await RecordingPolish.export(source: source, to: destination, options: chosen, clicks: clicks, cursor: cursor, keystrokes: keystrokes) { value in
                    Task { @MainActor in progress = value }
                }
                Analytics.track("recording_polished", ["backdrop": chosen.backdrop.rawValue, "zoom": chosen.zoomOnClicks,
                                                       "cursor": chosen.drawCursor, "keys": chosen.showKeystrokes, "blur": chosen.motionBlur,
                                                       "trimmed": chosen.trimStart > 0 || (chosen.trimEnd ?? 0) < duration])
                Toast.show("Polished recording saved", actionLabel: "Open", action: { NSWorkspace.shared.open(destination) },
                           secondaryLabel: "Show in Finder", secondaryAction: { NSWorkspace.shared.activateFileViewerSelecting([destination]) })
                onClose()
            } catch {
                self.error = error.localizedDescription
                exporting = false
            }
        }
    }
}
