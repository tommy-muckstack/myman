import AppKit

enum AgentComparison {
    struct Difference: Sendable {
        let changed: Int
        let compared: Int
        let regions: [CGRect]
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        let count = image.width * image.height
        guard count > 0, count <= 32_000_000 else { throw AgentError("TOO_LARGE", "Comparison supports up to 32 million pixels per image.") }
        var pixels = [UInt8](repeating: 255, count: count * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AgentError("INVALID_IMAGE", "Cannot decode comparison pixels.") }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
    static func difference(_ before: CGImage, _ after: CGImage, ignored: [CGRect], threshold: Int) throws -> Difference {
        guard before.width == after.width, before.height == after.height else { throw AgentError("SIZE_MISMATCH", "Screenshots must have equal pixel dimensions. Capture the same window size or crop them explicitly first.") }
        let bounds = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        guard (0...255).contains(threshold), ignored.count <= 50, ignored.allSatisfy({ !$0.isEmpty && bounds.contains($0) }) else { throw AgentError("INVALID_ARGUMENTS", "Ignored rectangles must fit inside the source image.") }
        let a = try pixels(before), b = try pixels(after), tile = 32, columns = (before.width + 31) / 32
        var changed = 0, compared = 0, cells = Set<Int>()
        for y in 0..<before.height {
            let spans = ignored.filter { CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY }
            for x in 0..<before.width {
                if spans.contains(where: { CGFloat(x) >= $0.minX && CGFloat(x) < $0.maxX }) { continue }
                compared += 1
                let i = (y * before.width + x) * 4
                if (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > threshold }) {
                    changed += 1; cells.insert((y / tile) * columns + x / tile)
                }
            }
        }
        var regions: [CGRect] = []
        while let first = cells.first {
            cells.remove(first); var queue = [first], index = 0
            var minX = first % columns, maxX = minX, minY = first / columns, maxY = minY
            while index < queue.count {
                let cell = queue[index]; index += 1
                let x = cell % columns, y = cell / columns
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for peer in [x > 0 ? cell - 1 : -1, x + 1 < columns ? cell + 1 : -1, cell - columns, cell + columns] where cells.remove(peer) != nil { queue.append(peer) }
            }
            regions.append(CGRect(x: minX * tile, y: minY * tile, width: (maxX - minX + 1) * tile, height: (maxY - minY + 1) * tile).intersection(bounds))
        }
        return Difference(changed: changed, compared: compared, regions: regions)
    }
    static func changedText(before: [ImageAnalysis.TextObservation], after: [ImageAnalysis.TextObservation], size: CGSize, ignored: [CGRect]) -> [String: [String]] {
        func texts(_ lines: [ImageAnalysis.TextObservation]) -> Set<String> {
            Set(lines.filter { line in !ignored.contains { $0.intersects(line.rect(in: size)) } }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        let a = texts(before), b = texts(after)
        return ["removed": Array(a.subtracting(b)).sorted(), "added": Array(b.subtracting(a)).sorted()]
    }
    @MainActor static func render(before: NSImage, after: NSImage, difference: Difference, ignored: [CGRect]) throws -> NSImage {
        let size = AgentImages.size(before), scale = min(1, 1400 / (size.width * 2))
        let panel = CGSize(width: size.width * scale, height: size.height * scale)
        return try AgentMediaStore.canvas(size: CGSize(width: panel.width * 2, height: panel.height + 32)) { context in
            context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: panel.width * 2, height: panel.height + 32))
            for (index, image) in [before, after].enumerated() {
                let offset = CGFloat(index) * panel.width
                image.draw(in: CGRect(x: offset, y: 0, width: panel.width, height: panel.height))
                for rect in difference.regions {
                    let r = CGRect(x: offset + rect.minX * scale, y: panel.height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
                    context.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor); context.fill(r)
                    context.setStrokeColor(NSColor.systemRed.cgColor); context.stroke(r, width: 1)
                }
                for rect in ignored {
                    context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
                    context.fill(CGRect(x: offset + rect.minX * scale, y: panel.height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale))
                }
                ((index == 0 ? "Before" : "After · differences highlighted") as NSString).draw(at: CGPoint(x: offset + 8, y: panel.height + 8), withAttributes: [.font: NSFont(name: "Gellix-Medium", size: 14) ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.white])
            }
        }
    }
}
