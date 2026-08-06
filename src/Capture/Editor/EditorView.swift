import AppKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, box, highlight, text, pixelate, crop, ocr
    var id: String { rawValue }

    /// SF Symbol name, or nil when the tool uses an MMIcon instead.
    var symbol: String? {
        switch self {
        case .select: return nil
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "eye.slash"
        case .crop: return "crop"
        case .ocr: return "text.viewfinder"
        }
    }

    var mmIcon: MMIcon? {
        self == .select ? .pointer : nil
    }

    var help: String {
        switch self {
        case .select: return "Select — click and drag existing annotations"
        case .arrow: return "Arrow — drag to point at something"
        case .box: return "Box — drag to frame something"
        case .highlight: return "Highlight — drag to mark something"
        case .text: return "Text — click to type"
        case .pixelate: return "Hide — drag to pixelate sensitive info"
        case .crop: return "Crop — drag to keep just that region"
        case .ocr: return "Select text — drag across the text in the image to copy it"
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var tool: EditorTool = .arrow
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var pendingText: (origin: CGPoint, id: UUID)?
    @State private var textDraft = ""
    @FocusState private var textFocused: Bool

    @State private var scanning = false
    @State private var showTranslate = false
    @State private var ocrForTranslate = ""
    private enum DragMode { case undecided, drawing, moving(UUID, last: CGPoint) }
    @State private var dragMode: DragMode = .undecided
    @State private var selectedAnnotation: UUID?

    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            canvas
                .padding(MM.Layout.paddingLarge)
        }
        .background(MM.Colors.background)
        .overlay(alignment: .topTrailing) {
            if showTranslate, #available(macOS 15.0, *) {
                TranslatePanelView(
                    sourceText: ocrForTranslate,
                    image: model.image,
                    provideObservations: { [weak model] in
                        guard let model else { return [] }
                        if let cached = model.textObservations { return cached }
                        return await ImageAnalysis.textObservations(model.image)
                    },
                    onApplyInPlace: { patches in
                        withAnimation(MM.Motion.gentle) {
                            model.translationPatches = patches
                            model.showTranslation = true
                            showTranslate = false
                        }
                    }
                ) {
                    withAnimation(MM.Motion.gentle) { showTranslate = false }
                }
                .padding(.top, 52)
                .padding(.trailing, MM.Layout.padding)
                .transition(.opacity)
            }
        }
        .onKeyPress(.escape) {
            if pendingText != nil { cancelText(); return .handled }
            return .ignored
        }
    }

    /// The translated text drawn over the live preview, matching renderFinal.
    private func translationLayer(scale: CGFloat) -> some View {
        Canvas { context, _ in
            for patch in model.translationPatches {
                let rect = CGRect(x: patch.rect.minX * scale, y: patch.rect.minY * scale,
                                  width: patch.rect.width * scale, height: patch.rect.height * scale)
                let pad = rect.insetBy(dx: -3 * scale, dy: -2 * scale)
                context.fill(Path(roundedRect: pad, cornerRadius: 3 * scale),
                             with: .color(Color(nsColor: patch.background)))
                let text = Text(patch.text)
                    .font(.system(size: patch.fontSize * scale,
                                  weight: patch.bold ? .semibold : .regular))
                    .foregroundColor(Color(nsColor: patch.textColor))
                context.draw(context.resolve(text), in: rect)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                toolButton(t)
            }

            Divider().frame(height: 18).overlay(MM.Colors.border).padding(.horizontal, 6)

            // Backdrop chips
            ForEach(BackdropStyle.allCases) { style in
                backdropChip(style)
            }

            Divider().frame(height: 18).overlay(MM.Colors.border).padding(.horizontal, 6)

            Button {
                model.removeBackground()
            } label: {
                Group {
                    if model.isRemovingBackground {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.and.background.dotted")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 30, height: 26)
                    .clickable(minSize: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.backgroundRemoved ? MM.Colors.textTertiary : MM.Colors.textSecondary)
            .disabled(model.isRemovingBackground || model.backgroundRemoved)
            .help("Cut out — remove the background behind the subject")

            Button {
                addPhoto()
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 26)
                    .clickable(minSize: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MM.Colors.textSecondary)
            .help("Photo — overlay an image from disk")

            if #available(macOS 15.0, *) {
                Button {
                    if showTranslate {
                        showTranslate = false
                    } else {
                        Task { @MainActor in
                            ocrForTranslate = await ImageAnalysis.analyze(model.image).text
                            withAnimation(MM.Motion.gentle) { showTranslate = true }
                        }
                    }
                } label: {
                    Image(systemName: "translate")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 26)
                        .clickable(minSize: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showTranslate ? MM.Colors.textPrimary : MM.Colors.textSecondary)
                .help("Translate — recognize the image's text and translate it on-device")
            }

            Button {
                withAnimation(MM.Motion.gentle) {
                    model.cornerRadius = model.cornerRadius == 0 ? 12 : (model.cornerRadius == 12 ? 24 : 0)
                }
            } label: {
                Image(systemName: "rectangle.roundedtop")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(model.cornerRadius > 0 ? MM.Colors.surface : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(model.cornerRadius > 0 ? MM.Colors.border : .clear, lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if model.cornerRadius > 0 {
                            Text("\(Int(model.cornerRadius))")
                                .font(MM.Fonts.metadata)
                                .foregroundStyle(MM.Colors.textTertiary)
                                .offset(x: -2, y: -1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.cornerRadius == 0 ? MM.Colors.textSecondary : MM.Colors.textPrimary)
            .help("Corners — round the image corners (cycles 0 / 12 / 24)")

            if !model.translationPatches.isEmpty {
                Button {
                    model.showTranslation.toggle()
                } label: {
                    Text(model.showTranslation ? "Translated" : "Original")
                        .font(MM.Fonts.hint)
                        .foregroundStyle(model.showTranslation
                                         ? MM.Colors.background : MM.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(model.showTranslation
                                                   ? MM.Colors.textPrimary : MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(
                            model.showTranslation ? Color.clear : MM.Colors.border, lineWidth: 1))
                        .fixedSize()
                        .clickable(minSize: 22)
                }
                .buttonStyle(.plain)
                .help("Toggle the in-place translation layer")
            }

            Spacer()

            if model.didCopyText {
                Text("Copied")
                    .font(MM.Fonts.hint)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            if selectedAnnotation != nil {
                Button {
                    if let id = selectedAnnotation {
                        model.remove(id)
                        selectedAnnotation = nil
                    }
                } label: {
                    IconView(icon: .trash, size: 14, color: MM.Colors.textSecondary)
                        .frame(width: 30, height: 26)
                        .clickable(minSize: 30)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: [])
                .help("Delete selected annotation (⌫)")
            }

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 26)
                    .clickable(minSize: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MM.Colors.textSecondary)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")

            Button {
                model.copyToClipboard()
            } label: {
                IconView(icon: .copy, size: 14, color: MM.Colors.textSecondary)
                    .frame(width: 30, height: 26)
                    .clickable(minSize: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy image (⇧⌘C)")

            Button {
                model.save()
                onDone()
            } label: {
                Text("Save")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .fixedSize()
                    .background(Capsule().fill(MM.Colors.textPrimary))
                    .clickable(minSize: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save (⌘S)")
        }
        .padding(.horizontal, MM.Layout.padding)
        // One fixed row height: every control centers on the same axis, and
        // nothing (looking at you, pill buttons) can stretch the bar.
        .frame(height: 46)
    }

    private func toolButton(_ t: EditorTool) -> some View {
        Button {
            withAnimation(MM.Motion.gentle) { tool = t }
            if t == .ocr {
                scanning = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(750))
                    withAnimation(MM.Motion.gentle) { scanning = false }
                }
            }
        } label: {
            Group {
                if let mm = t.mmIcon {
                    IconView(icon: mm, size: 14,
                             color: tool == t ? MM.Colors.textPrimary : MM.Colors.textSecondary)
                } else {
                    Image(systemName: t.symbol ?? "questionmark")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tool == t ? MM.Colors.surface : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tool == t ? MM.Colors.border : .clear, lineWidth: 1)
                )
                .clickable(minSize: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tool == t ? MM.Colors.textPrimary : MM.Colors.textSecondary)
        .help(t.help)
    }

    private func backdropChip(_ style: BackdropStyle) -> some View {
        Button {
            withAnimation(MM.Motion.gentle) { model.backdrop = style }
        } label: {
            Group {
                if let colors = style.colors {
                    Circle().fill(
                        LinearGradient(
                            colors: colors.map { Color(nsColor: $0) },
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                } else {
                    Circle()
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                        .overlay(
                            Rectangle()
                                .fill(MM.Colors.textTertiary)
                                .frame(width: 12, height: 1)
                                .rotationEffect(.degrees(-45))
                        )
                }
            }
            .frame(width: 16, height: 16)
            .overlay(
                Circle().strokeBorder(
                    model.backdrop == style ? MM.Colors.textPrimary : .clear, lineWidth: 1.5
                )
                .padding(-3)
            )
            // The None chip is a hollow ring — without an explicit hit shape
            // its transparent center ignores clicks entirely.
            .clickable(minSize: 24)
        }
        .buttonStyle(.plain)
        .help(style == .none ? "No backdrop" : "\(style.rawValue) backdrop")
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let scale = fitScale(in: geo.size)
            let displaySize = CGSize(
                width: model.imageSize.width * scale,
                height: model.imageSize.height * scale
            )

            ZStack(alignment: .topLeading) {
                // Sized to the image (+ padding) — a bare shape is greedy and
                // would swallow the whole window, stranding small cutouts in
                // the top-left corner.
                backdropPreview
                    .frame(
                        width: displaySize.width + (model.backdrop == .none ? 0 : 48),
                        height: displaySize.height + (model.backdrop == .none ? 0 : 48)
                    )

                // Transparency indicator: a cut-out with no backdrop shows
                // the classic checkerboard, so "cleared" is visibly cleared.
                if model.backdrop == .none, model.backgroundRemoved {
                    Checkerboard()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .opacity(0.5)
                } else if model.backdrop == .none, model.cornerRadius > 0 {
                    Color.black
                        .frame(width: displaySize.width, height: displaySize.height)
                }

                Image(nsImage: model.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(
                        cornerRadius: model.effectiveCornerRadius * scale, style: .continuous))
                    .shadow(color: model.backdrop == .none ? .clear : .black.opacity(0.3),
                            radius: 12, y: 4)
                    .padding(model.backdrop == .none ? 0 : 24)

                if model.showTranslation, !model.translationPatches.isEmpty {
                    translationLayer(scale: scale)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .allowsHitTesting(false)
                        .padding(model.backdrop == .none ? 0 : 24)
                }

                annotationLayer(scale: scale)
                    .padding(model.backdrop == .none ? 0 : 24)

                Color.clear
                    .frame(width: displaySize.width, height: displaySize.height)
                    .contentShape(Rectangle())
                    .gesture(canvasGesture(scale: scale),
                             including: tool == .ocr ? .subviews : .all)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let point = CGPoint(x: location.x / scale, y: location.y / scale)
                            if tool == .select || model.hitTest(
                                point, tolerance: 10 / scale, selected: selectedAnnotation) != nil {
                                if model.hitTest(point, tolerance: 10 / scale,
                                                 selected: selectedAnnotation) != nil {
                                    NSCursor.openHand.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            } else {
                                NSCursor.crosshair.set()
                            }
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                    .padding(model.backdrop == .none ? 0 : 24)

                if tool == .ocr {
                    LiveTextView(image: model.image)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipShape(RoundedRectangle(
                            cornerRadius: model.backdrop == .none ? 0 : 8, style: .continuous))
                        .padding(model.backdrop == .none ? 0 : 24)
                        .overlay {
                            if scanning {
                                ScanSweep()
                                    .frame(width: displaySize.width, height: displaySize.height)
                                    .padding(model.backdrop == .none ? 0 : 24)
                                    .allowsHitTesting(false)
                            }
                        }
                        .transition(.opacity)
                }

                if let pending = pendingText {
                    TextField("", text: $textDraft)
                        .textFieldStyle(.plain)
                        .font(MM.Fonts.outfit(model.annotationFontSize * scale, .semiBold))
                        .foregroundStyle(Color(nsColor: model.annotationColor))
                        .focused($textFocused)
                        .frame(width: 240)
                        .offset(
                            x: pending.origin.x * scale + (model.backdrop == .none ? 0 : 24),
                            y: pending.origin.y * scale + (model.backdrop == .none ? 0 : 24)
                        )
                        .onSubmit(commitText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    private var backdropPreview: some View {
        Group {
            if let colors = model.backdrop.colors {
                RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                    .fill(LinearGradient(
                        colors: colors.map { Color(nsColor: $0) },
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
        }
    }

    private func annotationLayer(scale: CGFloat) -> some View {
        Canvas { context, _ in
            let color = Color(nsColor: model.annotationColor)

            for annotation in model.annotations {
                draw(annotation, in: &context, scale: scale, color: color)
            }
            // Selection halo — a quiet dashed outline you can grab.
            if let selected = model.annotations.first(where: { $0.id == selectedAnnotation }) {
                let b = model.bounds(of: selected)
                let scaled = CGRect(x: b.origin.x * scale - 5, y: b.origin.y * scale - 5,
                                    width: b.width * scale + 10, height: b.height * scale + 10)
                context.stroke(
                    Path(roundedRect: scaled, cornerRadius: 4),
                    with: .color(.gray.opacity(0.7)),
                    style: .init(lineWidth: 1, dash: [4, 3])
                )
            }
            // Live preview of the in-flight drag
            if case .drawing = dragMode, let start = dragStart, let current = dragCurrent {
                if tool == .crop {
                    // Dashed keep-region with everything else dimmed.
                    let r = rect(from: start, to: current)
                    let scaled = CGRect(x: r.origin.x * scale, y: r.origin.y * scale,
                                        width: r.width * scale, height: r.height * scale)
                    var dim = Path(CGRect(origin: .zero, size: CGSize(
                        width: model.imageSize.width * scale,
                        height: model.imageSize.height * scale)))
                    dim.addRect(scaled)
                    context.fill(dim, with: .color(.black.opacity(0.35)), style: .init(eoFill: true))
                    context.stroke(Path(scaled), with: .color(.white),
                                   style: .init(lineWidth: 1.5, dash: [6, 4]))
                } else if tool != .select && tool != .ocr && tool != .text {
                    let preview = previewAnnotation(from: start, to: current)
                    draw(preview, in: &context, scale: scale, color: color.opacity(0.85))
                }
            }
        }
        .allowsHitTesting(false)
        .frame(
            width: model.imageSize.width * scale,
            height: model.imageSize.height * scale
        )
    }

    private func draw(_ annotation: Annotation, in context: inout GraphicsContext,
                      scale: CGFloat, color: Color) {
        switch annotation {
        case .arrow(_, let from, let to):
            let f = CGPoint(x: from.x * scale, y: from.y * scale)
            let t = CGPoint(x: to.x * scale, y: to.y * scale)
            var line = Path()
            let angle = atan2(t.y - f.y, t.x - f.x)
            let head: CGFloat = 12
            line.move(to: f)
            line.addLine(to: CGPoint(x: t.x - cos(angle) * head * 0.6,
                                     y: t.y - sin(angle) * head * 0.6))
            context.stroke(line, with: .color(color), style: .init(lineWidth: 3, lineCap: .round))
            var headPath = Path()
            headPath.move(to: t)
            headPath.addLine(to: CGPoint(x: t.x - head * cos(angle - .pi / 7),
                                         y: t.y - head * sin(angle - .pi / 7)))
            headPath.addLine(to: CGPoint(x: t.x - head * cos(angle + .pi / 7),
                                         y: t.y - head * sin(angle + .pi / 7)))
            headPath.closeSubpath()
            context.fill(headPath, with: .color(color))

        case .box(_, let rect):
            let scaled = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
            context.stroke(
                Path(roundedRect: scaled, cornerRadius: 3),
                with: .color(color), style: .init(lineWidth: 3)
            )

        case .text(let id, let string, let origin):
            if pendingText?.id == id { break }
            // Same image-space size the export uses, scaled for display.
            context.draw(
                Text(string)
                    .font(MM.Fonts.outfit(model.annotationFontSize * scale, .semiBold))
                    .foregroundColor(color),
                at: CGPoint(x: origin.x * scale, y: origin.y * scale),
                anchor: .topLeading
            )

        case .pixelate(let id, let rect):
            let scaled = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
            if let preview = model.pixelatePreviews[id] {
                context.draw(Image(nsImage: preview), in: scaled)
            } else {
                context.fill(Path(scaled), with: .color(.gray.opacity(0.6)))
            }

        case .highlight(_, let rect):
            let scaled = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
            context.drawLayer { layer in
                layer.blendMode = .multiply
                layer.fill(Path(scaled), with: .color(Color(nsColor: EditorModel.highlightColor)))
            }

        case .image(let id, let rect):
            let scaled = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
            if let overlay = model.overlayImages[id] {
                context.draw(Image(nsImage: overlay), in: scaled)
            }
        }
    }

    private func addPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let overlay = NSImage(contentsOf: url) else { return }
        model.addOverlayImage(overlay)
        tool = .select
    }

    // MARK: Gestures

    private func canvasGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // The gesture lives on a layer that IS the image — divide by
                // scale and you have image coordinates. No offset math.
                let point = clampToImage(CGPoint(
                    x: value.location.x / scale,
                    y: value.location.y / scale
                ))
                let start = CGPoint(
                    x: value.startLocation.x / scale,
                    y: value.startLocation.y / scale
                )

                // Decide once, on the first tick: pressing an existing
                // annotation moves it; pressing empty canvas draws.
                if case .undecided = dragMode {
                    if tool != .ocr,
                       let hit = model.hitTest(start, tolerance: 10 / scale, selected: selectedAnnotation) {
                        dragMode = .moving(hit, last: start)
                        selectedAnnotation = hit
                    } else {
                        dragMode = .drawing
                        selectedAnnotation = nil
                        dragStart = start
                    }
                }

                switch dragMode {
                case .moving(let id, let last):
                    NSCursor.closedHand.set()
                    model.move(id, by: CGVector(dx: point.x - last.x, dy: point.y - last.y))
                    dragMode = .moving(id, last: point)
                case .drawing:
                    dragCurrent = point
                case .undecided:
                    break
                }
            }
            .onEnded { _ in
                defer { dragMode = .undecided; dragStart = nil; dragCurrent = nil }

                switch dragMode {
                case .moving(let id, _):
                    model.refreshPixelateIfNeeded(id)

                case .drawing:
                    guard let start = dragStart, let end = dragCurrent else { return }
                    switch tool {
                    case .select:
                        return
                    case .text:
                        beginText(at: start)
                        return
                    case .crop:
                        let region = rect(from: start, to: end)
                        guard region.width > 10, region.height > 10 else { return }
                        model.applyCrop(region)
                        selectedAnnotation = nil
                        tool = .select
                        return
                    case .ocr:
                        return // Live Text owns selection in this mode
                    default:
                        break
                    }
                    let distance = hypot(end.x - start.x, end.y - start.y)
                    guard distance > 6 else { return }
                    let annotation = previewAnnotation(from: start, to: end)
                    model.add(annotation)
                    selectedAnnotation = annotation.id

                case .undecided:
                    break
                }
            }
    }

    private func previewAnnotation(from start: CGPoint, to end: CGPoint) -> Annotation {
        switch tool {
        case .arrow, .text, .select, .crop, .ocr:
            return .arrow(id: UUID(), from: start, to: end)
        case .box:
            return .box(id: UUID(), rect: rect(from: start, to: end))
        case .highlight:
            return .highlight(id: UUID(), rect: rect(from: start, to: end))
        case .pixelate:
            return .pixelate(id: UUID(), rect: rect(from: start, to: end))
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), model.imageSize.width),
                y: min(max(0, p.y), model.imageSize.height))
    }

    private func fitScale(in available: CGSize) -> CGFloat {
        let inset: CGFloat = model.backdrop == .none ? 0 : 48
        let w = (available.width - inset) / model.imageSize.width
        let h = (available.height - inset) / model.imageSize.height
        return max(0.05, min(min(w, h), 1))
    }

    // MARK: Text tool

    private func beginText(at origin: CGPoint) {
        commitText()
        let id = UUID()
        pendingText = (origin, id)
        textDraft = ""
        textFocused = true
    }

    private func commitText() {
        guard let pending = pendingText else { return }
        let trimmed = textDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let annotation = Annotation.text(id: pending.id, string: trimmed, origin: pending.origin)
            model.add(annotation)
            selectedAnnotation = annotation.id
            // Hand back the pointer so the fresh text can be dragged into place.
            withAnimation(MM.Motion.gentle) { tool = .select }
        }
        pendingText = nil
        textDraft = ""
    }

    private func cancelText() {
        pendingText = nil
        textDraft = ""
    }
}

/// One-shot scan sweep when Live Text activates — the "it's reading the
/// image" moment.
private struct ScanSweep: View {
    @State private var offset: CGFloat = -0.15

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color.accentColor.opacity(0.35), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: geo.size.height * 0.22)
            .offset(y: geo.size.height * offset)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7)) { offset = 1.0 }
            }
        }
        .clipped()
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0...Int(size.height / cell) {
                for col in 0...Int(size.width / cell) where (row + col).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                    width: cell, height: cell)),
                        with: .color(.gray.opacity(0.25))
                    )
                }
            }
        }
    }
}
