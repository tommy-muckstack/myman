import AppKit
@preconcurrency import Vision

/// On-device Vision analysis: OCR text + scene labels, combined into the
/// searchable text that lands in the shared index.
enum ImageAnalysis {
    /// One recognized text line and its Vision-normalized bounding box
    /// (bottom-left origin, 0...1).
    struct TextObservation: Identifiable {
        let id = UUID()
        let text: String
        let box: CGRect

        /// Convert to image coordinates (points, top-left origin).
        func rect(in imageSize: CGSize) -> CGRect {
            CGRect(
                x: box.minX * imageSize.width,
                y: (1 - box.maxY) * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            )
        }
    }

    /// Line-level OCR with geometry — powers the editor's text-selection tool.
    static func textObservations(_ image: NSImage) async -> [TextObservation] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
                let observations = (request.results ?? []).compactMap { observation -> TextObservation? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return TextObservation(text: text, box: observation.boundingBox)
                }
                continuation.resume(returning: observations)
            }
        }
    }

    struct Result {
        let text: String
        let labels: [String]

        var searchableText: String {
            [text, labels.joined(separator: " ")]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    static func analyze(_ image: NSImage) async -> Result {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Result(text: "", labels: [])
        }
        async let text = recognizeText(cgImage)
        async let labels = classify(cgImage)
        return await Result(text: text, labels: labels)
    }

    private static func recognizeText(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .utility).async {
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    private static func classify(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .utility).async {
                try? handler.perform([request])
                let labels = (request.results ?? [])
                    .filter { $0.confidence > 0.5 }
                    .prefix(10)
                    .map { $0.identifier.lowercased() }
                continuation.resume(returning: Array(labels))
            }
        }
    }
}
