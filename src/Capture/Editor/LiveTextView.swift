import AppKit
import SwiftUI
import VisionKit

/// Apple's Live Text, exactly as Photos does it: the image's text becomes
/// real selectable text — drag through characters, ⌘C, context menu, data
/// detectors. A compact action toolbar appears whenever a selection exists.
struct LiveTextView: NSViewRepresentable {
    let image: NSImage

    final class ChipModel: ObservableObject {
        @Published var visible = false
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
        let chip = NSHostingView(rootView: LiveTextActions(model: model) { [weak overlay] in
            guard let overlay, overlay.hasActiveTextSelection else { return nil }
            return overlay.selectedText
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

        context.coordinator.imageView = imageView
        context.coordinator.overlay = overlay
        context.coordinator.update(image: image)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.update(image: image) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.analysisTask?.cancel()
        coordinator.pollTimer?.invalidate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        let chipModel = ChipModel()
        var pollTimer: Timer?
        weak var imageView: NSImageView?
        weak var overlay: ImageAnalysisOverlayView?
        private var currentImage: NSImage?
        var analysisTask: Task<Void, Never>?

        func update(image: NSImage) {
            guard currentImage !== image else { return }
            currentImage = image
            imageView?.image = image
            analysisTask?.cancel()
            overlay?.analysis = nil
            chipModel.visible = false
            analysisTask = Task { @MainActor [weak self] in
                let analyzer = ImageAnalyzer()
                guard let analysis = try? await analyzer.analyze(
                    image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text])),
                      !Task.isCancelled else { return }
                self?.overlay?.analysis = analysis
            }
        }

        deinit { pollTimer?.invalidate(); analysisTask?.cancel() }
    }
}

private struct LiveTextActions: View {
    @ObservedObject var model: LiveTextView.ChipModel
    var text: () -> String?

    var body: some View {
        SelectedTextToolbar(text: text)
            .opacity(model.visible ? 1 : 0)
            .animation(MM.Motion.gentle, value: model.visible)
            .allowsHitTesting(model.visible)
    }
}
