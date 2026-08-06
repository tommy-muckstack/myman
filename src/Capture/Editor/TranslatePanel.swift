import SwiftUI
import Translation

// Screenshot translation via Apple's on-device Translation framework
// (macOS 15+, free, no keys; language models download on first use).
// OCR the image, pick a target language, copy the result.

@available(macOS 15.0, *)
struct TranslatePanelView: View {
    let sourceText: String
    var image: NSImage?
    var provideObservations: (() async -> [ImageAnalysis.TextObservation])?
    var onApplyInPlace: (([TranslationPatch]) -> Void)?
    var onDismiss: () -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var targetID = "en"
    @State private var output = ""
    @State private var isWorking = false
    @State private var copied = false
    @State private var inPlace = false
    @State private var pendingObservations: [ImageAnalysis.TextObservation] = []

    private static let targets: [(id: String, label: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("pt", "Portuguese"), ("it", "Italian"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Translate")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                Picker("", selection: $targetID) {
                    ForEach(Self.targets, id: \.id) { target in
                        Text(target.label).tag(target.id)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                IconView(icon: .close, size: 14, color: MM.Colors.textTertiary)
                    .clickable(minSize: 22)
                    .onTapGesture { onDismiss() }
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if output.isEmpty {
                Text(sourceText.isEmpty
                     ? "No text was found in this image."
                     : "Pick a language — translation runs on-device.")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                if !sourceText.isEmpty, onApplyInPlace != nil {
                    translateOnImageButton
                }
            } else {
                ScrollView {
                    Text(output)
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        IconView(icon: .copy, size: 12,
                                 color: copied ? .green : MM.Colors.textPrimary)
                        Text(copied ? "Copied" : "Copy translation")
                    }
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(copied ? .green : MM.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MM.Colors.surface))
                    .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                    .clickable(minSize: 24)
                }
                .buttonStyle(.plain)
                if onApplyInPlace != nil {
                    translateOnImageButton
                }
            }
        }
        .padding(MM.Layout.padding)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                    .strokeBorder(MM.Colors.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .onAppear { retranslate() }
        .onChange(of: targetID) { _, _ in retranslate() }
        .translationTask(configuration) { session in
            guard !sourceText.isEmpty else { return }
            if inPlace, let image, !pendingObservations.isEmpty {
                do {
                    let requests = pendingObservations.map {
                        TranslationSession.Request(sourceText: $0.text)
                    }
                    let responses = try await session.translations(from: requests)
                    let patches = InPlaceTranslation.patches(
                        image: image,
                        observations: pendingObservations,
                        translations: responses.map(\.targetText))
                    Analytics.track("screenshot_translated_inplace",
                                    ["target": targetID, "lines": patches.count])
                    onApplyInPlace?(patches)
                    inPlace = false
                    isWorking = false
                    onDismiss()
                } catch {
                    inPlace = false
                    isWorking = false
                    output = "Translation unavailable — the language model may still be downloading. Try again in a moment."
                }
                return
            }
            do {
                let response = try await session.translate(sourceText)
                output = response.targetText
                Analytics.track("screenshot_translated", ["target": targetID])
            } catch {
                output = "Translation unavailable — the language model may still be downloading. Try again in a moment."
            }
            isWorking = false
        }
    }

    private var translateOnImageButton: some View {
        Button {
            isWorking = true
            Task { @MainActor in
                pendingObservations = await provideObservations?() ?? []
                guard !pendingObservations.isEmpty else {
                    isWorking = false
                    output = "No positioned text found in this image."
                    return
                }
                inPlace = true
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: nil, target: Locale.Language(identifier: targetID))
                } else {
                    configuration?.invalidate() // re-fire the translation task
                }
            }
        } label: {
            HStack(spacing: 5) {
                IconView(icon: .write, size: 12, color: MM.Colors.background)
                Text("Translate on image")
            }
            .font(MM.Fonts.secondary)
            .foregroundStyle(MM.Colors.background)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(MM.Colors.textPrimary))
            .clickable(minSize: 24)
        }
        .buttonStyle(.plain)
        .help("Redraw the screenshot with translated text in place")
    }

    private func retranslate() {
        guard !sourceText.isEmpty else { return }
        isWorking = true
        output = ""
        configuration = TranslationSession.Configuration(
            source: nil, // auto-detect
            target: Locale.Language(identifier: targetID)
        )
    }
}
