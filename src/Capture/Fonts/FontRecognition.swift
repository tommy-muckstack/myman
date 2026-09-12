import AppKit
import ImageIO
@preconcurrency import Vision

/// Fast Vision recognition returns character rectangles (accurate returns word
/// rectangles). Crops are further normalized and reviewed in the workbench.
final class FontRecognition: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    func cancel() { lock.lock(); request?.cancel(); request = nil; lock.unlock() }
    func recognize(_ data: Data) async throws -> [String: Any] {
        guard data.count <= 24 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AgentError("INVALID_IMAGE", "Selected text region is too large or invalid.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast; request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                self.lock.lock(); self.request?.cancel(); self.request = request; self.lock.unlock()
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    var characters: [[String: Any]] = [], truncated = false
                    for (lineID, observation) in (request.results ?? []).enumerated() {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        var seen = Set<String>()
                        for index in candidate.string.indices {
                            let char = String(candidate.string[index])
                            guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first, (33...126).contains(scalar.value),
                                  let box = try candidate.boundingBox(for: index..<candidate.string.index(after: index))?.boundingBox else { continue }
                            let rect = Self.pixels(box, width: width, height: height)
                            guard rect.width >= 1, rect.height >= 1, rect.width <= Double(width), rect.height <= Double(height) else { continue }
                            // Vision sometimes returns the entire word for multiple letters.
                            // Such rectangles cannot identify individual captured glyphs.
                            let key = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
                            guard seen.insert(key).inserted else { continue }
                            if characters.count == 600 { truncated = true; break }
                            characters.append(["char": char, "bbox": ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height], "confidence": Double(candidate.confidence) * 100, "lineId": lineID])
                        }
                        if truncated { break }
                    }
                    continuation.resume(returning: ["characters": characters, "truncated": truncated])
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func pixels(_ box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: box.minX * Double(width), y: (1 - box.maxY) * Double(height), width: box.width * Double(width), height: box.height * Double(height))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
