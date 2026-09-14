import AppKit

enum ScrollStitcher {
    enum Result { case unchanged, appended(CGImage, Int), noOverlap }
    static func signature(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48 * image.height)
        bytes.withUnsafeMutableBytes { storage in
            if let context = CGContext(data: storage.baseAddress, width: 48, height: image.height, bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: image.height))
            }
        }
        return bytes
    }
    /// Only appends when an overlapping viewport can be matched. A weak match
    /// leaves the existing capture unchanged instead of silently losing rows.
    static func append(previous: CGImage, next: CGImage, composite: CGImage) throws -> Result {
        guard previous.width == next.width, previous.height == next.height, composite.width == next.width, next.height >= 100 else { throw AgentError("INVALID_ARGUMENTS", "Keep the selected capture area the same size.") }
        let a = signature(previous), b = signature(next), height = next.height
        func score(_ shift: Int) -> Double {
            var difference = 0.0, count = 0
            for y in stride(from: 0, to: height - shift, by: max(5, height / 80)) {
                for x in stride(from: 4, to: 44, by: 2) {
                    difference += Double(abs(Int(a[(y + shift) * 48 + x]) - Int(b[y * 48 + x])))
                    count += 1
                }
            }
            return difference / Double(max(1, count)) / 255
        }
        if score(0) < 0.002 { return .unchanged }
        let candidates = (1...height - max(64, height / 4)).map { ($0, score($0)) }.sorted { $0.1 < $1.1 }
        guard let fine = candidates.first, fine.1 < 0.025 else { return .noOverlap }
        // Repeated stripes/rows can match several offsets. Refuse ambiguous
        // matches rather than silently dropping or duplicating content.
        if candidates.contains(where: { abs($0.0 - fine.0) > 2 && $0.1 < fine.1 + 0.003 }) { return .noOverlap }
        let shift = fine.0, total = composite.height + shift
        guard total <= 20000, total * next.width <= 40_000_000 else { throw AgentError("TOO_LARGE", "This scrolling capture reached its size limit. Save it and start another.") }
        guard let context = CGContext(data: nil, width: next.width, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let tail = next.cropping(to: CGRect(x: 0, y: next.height - shift, width: next.width, height: shift)) else { throw AgentError("CAPTURE_FAILED", "Could not assemble the scrolling capture.") }
        context.draw(composite, in: CGRect(x: 0, y: shift, width: composite.width, height: composite.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: next.width, height: shift))
        guard let output = context.makeImage() else { throw AgentError("CAPTURE_FAILED", "Could not render the scrolling capture.") }
        return .appended(output, shift)
    }
}
