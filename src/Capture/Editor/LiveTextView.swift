import AppKit
import SwiftUI
import VisionKit

/// Apple's Live Text, exactly as Photos does it: the image's text becomes
/// real selectable text — drag through characters, ⌘C, context menu, data
/// detectors. A floating Copy chip appears whenever a selection exists.
struct LiveTextView: NSViewRepresentable {
    let image: NSImage

    final class ChipModel: ObservableObject {
        @Published var visible = false
        @Published var copied = false
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.trackingImageView = imageView
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

        for view in [imageView, overlay] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        let model = context.coordinator.chipModel
        let chip = NSHostingView(rootView: CopyChip(model: model) { [weak overlay] in
            guard let overlay else { return }
            let text = overlay.selectedText
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Analytics.track("editor_text_copied", ["chars": text.count])
            model.copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                model.copied = false
            }
        })
        chip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chip.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
        ])

        // VisionKit exposes no selection-changed callback on macOS — poll.
        context.coordinator.pollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25, repeats: true
        ) { [weak overlay, weak model] _ in
            Task { @MainActor in
                guard let overlay, let model else { return }
                let has = overlay.hasActiveTextSelection
                if model.visible != has { model.visible = has }
            }
        }

        let target = image
        Task { @MainActor in
            let analyzer = ImageAnalyzer()
            if let analysis = try? await analyzer.analyze(
                target, orientation: .up, configuration: ImageAnalyzer.Configuration([.text])) {
                overlay.analysis = analysis
            }
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let chipModel = ChipModel()
        var pollTimer: Timer?
        deinit { pollTimer?.invalidate() }
    }
}

private struct CopyChip: View {
    @ObservedObject var model: LiveTextView.ChipModel
    var onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 5) {
                if model.copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    IconView(icon: .copy, size: 12, color: .white)
                }
                Text(model.copied ? "Copied" : "Copy")
            }
            .font(MM.Fonts.secondary)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.75)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(model.visible || model.copied ? 1 : 0)
        .animation(MM.Motion.gentle, value: model.visible)
        .animation(MM.Motion.gentle, value: model.copied)
        .allowsHitTesting(model.visible || model.copied)
    }
}
