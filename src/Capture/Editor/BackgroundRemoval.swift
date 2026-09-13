import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Vision

/// Flat screenshots have no photographic subject for Vision to segment. Remove
/// only border-connected pixels of a confidently uniform surround first.
enum BackgroundRemoval {
    static func remove(_ image: CGImage) -> CGImage? {
        if let flat = flatBackground(image) { return flat }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else { return nil }
        let input = CIImage(cgImage: image), filter = CIFilter.blendWithMask()
        filter.inputImage = input; filter.maskImage = CIImage(cvPixelBuffer: buffer)
        filter.backgroundImage = CIImage(color: .clear).cropped(to: input.extent)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent), hasNewTransparency(cg, original: image) else { return nil }
        return cg
    }
    static func flatBackground(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height, count = width * height
        guard width >= 8, height >= 8, count <= 32_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: count * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var border: [Int] = []
        let strideSize = max(1, (width + height) / 1000)
        for x in stride(from: 0, to: width, by: strideSize) { border += [x, (height - 1) * width + x] }
        for y in stride(from: 1, to: height - 1, by: strideSize) { border += [y * width, y * width + width - 1] }
        let opaque = border.filter { pixels[$0 * 4 + 3] >= 32 }
        guard opaque.count >= border.count * 3 / 4 else { return nil }
        func channel(_ p: Int, _ c: Int) -> Int {
            let alpha = Int(pixels[p * 4 + 3])
            return alpha == 0 ? 0 : min(255, Int(pixels[p * 4 + c]) * 255 / alpha)
        }
        func key(_ p: Int) -> Int { channel(p, 0) / 16 * 256 + channel(p, 1) / 16 * 16 + channel(p, 2) / 16 }
        let histogram = Dictionary(grouping: opaque, by: key)
        guard let group = histogram.values.max(by: { $0.count < $1.count }), group.count >= border.count * 3 / 5 else { return nil }
        let color = (0..<3).map { c in group.map { channel($0, c) }.sorted()[group.count / 2] }
        func similar(_ p: Int) -> Bool {
            let i = p * 4
            return pixels[i + 3] == 0 || ((0..<3).allSatisfy { abs(channel(p, $0) - color[$0]) <= 24 })
        }
        var mask = [UInt8](repeating: 0, count: count), queue: [UInt32] = []
        func visit(_ p: Int) {
            guard mask[p] == 0 else { return }
            if similar(p) { mask[p] = 1; queue.append(UInt32(p)) } else { mask[p] = 2 }
        }
        for x in 0..<width { visit(x); visit((height - 1) * width + x) }
        for y in 0..<height { visit(y * width); visit(y * width + width - 1) }
        var head = 0
        while head < queue.count {
            let p = Int(queue[head]); head += 1
            if p % width > 0 { visit(p - 1) }; if p % width < width - 1 { visit(p + 1) }
            if p >= width { visit(p - width) }; if p < count - width { visit(p + width) }
        }
        guard queue.count >= max(4, count / 200), count - queue.count >= max(4, count / 10000) else { return nil }
        // Decontaminate a one-pixel antialiased edge using a nearby interior
        // color. Enclosed text/white panels never enter this border mask.
        let original = pixels
        for p in 0..<count where mask[p] == 2 && pixels[p * 4 + 3] >= 250 {
            let x = p % width, y = p / width
            var interior = p, best = 0.0
            for yy in max(0, y - 2)...min(height - 1, y + 2) {
                for xx in max(0, x - 2)...min(width - 1, x + 2) {
                    let q = yy * width + xx
                    guard mask[q] != 1 else { continue }
                    let distance = (0..<3).reduce(0.0) { $0 + pow(Double(Int(original[q * 4 + $1]) - color[$1]), 2) }
                    if distance > best { best = distance; interior = q }
                }
            }
            guard best > 4000 else { continue }
            let delta = (0..<3).map { Double(Int(original[interior * 4 + $0]) - color[$0]) }
            let observed = (0..<3).map { Double(Int(original[p * 4 + $0]) - color[$0]) }
            let alpha = zip(delta, observed).reduce(0.0) { $0 + $1.0 * $1.1 } / best
            let residual = (0..<3).map { abs(observed[$0] - alpha * delta[$0]) }.max() ?? 255
            guard alpha > 0, alpha < 0.98, residual < 12 else { continue }
            for channel in 0..<3 { pixels[p * 4 + channel] = UInt8(clamping: Int((Double(original[interior * 4 + channel]) * alpha).rounded())) }
            pixels[p * 4 + 3] = UInt8(clamping: Int((255 * alpha).rounded()))
        }
        for p in queue { let i = Int(p) * 4; pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0 }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    private static func hasNewTransparency(_ image: CGImage, original: CGImage) -> Bool {
        func alpha(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 128 * 128)
            if let ctx = CGContext(data: &bytes, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) { ctx.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128)) }
            return bytes
        }
        let before = alpha(original), after = alpha(image)
        return zip(before, after).filter { Int($0.0) - Int($0.1) > 20 }.count > 80 && after.filter { $0 > 128 }.count > 16
    }
}
