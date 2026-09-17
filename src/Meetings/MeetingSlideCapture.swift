import AppKit

/// Owns one recording's slide pipeline. Only completed files belong to a
/// meeting; a capture still running when it stops must clean up after itself.
@MainActor
final class MeetingSlideCapture {
    typealias Writer = @Sendable (CGImage, [Float]?, URL) throws -> [Float]?

    private struct Session {
        let token = UUID()
        let meetingID: String
        let folder: URL
    }

    private let writer: Writer
    private var session: Session?
    private var busy = false
    private var pendingWrite: Task<[Float]?, Never>?
    private var lastFingerprint: [Float]?
    private(set) var paths: [String] = []

    init(writer: @escaping Writer = { image, previous, url in
        try MeetingSlideWriter.saveIfChanged(image, previous: previous, url: url)
    }) {
        self.writer = writer
    }

    func start(meetingID: String, folder: URL) {
        _ = finish()
        session = Session(meetingID: meetingID, folder: folder)
    }

    func finish() -> [String] {
        session = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        busy = false
        lastFingerprint = nil
        let saved = paths
        paths = []
        return saved
    }

    func capture(meetingID: String, image: () async -> CGImage?,
                 inspect: (CGImage) async -> Void) async {
        guard let session, session.meetingID == meetingID, !busy else { return }
        busy = true
        defer {
            if self.session?.token == session.token { busy = false; pendingWrite = nil }
        }
        guard let image = await image(), self.session?.token == session.token else { return }
        await inspect(image)
        guard self.session?.token == session.token, paths.count < 24 else { return }

        let url = session.folder.appendingPathComponent("\(meetingID)-slide-\(paths.count).png")
        let previous = lastFingerprint
        let writer = self.writer
        // A Task inheriting this actor would still encode PNGs on the UI
        // thread. Keep fingerprinting, encoding and disk I/O detached.
        let work = Task.detached(priority: .utility) {
            autoreleasepool { try? writer(image, previous, url) }
        }
        pendingWrite = work
        let fingerprint = await work.value
        guard self.session?.token == session.token else {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: url)
            }.value
            return
        }
        guard let fingerprint else { return }
        lastFingerprint = fingerprint
        paths.append(url.path)
    }
}

enum MeetingSlideWriter {
    /// Returns a fingerprint only after its PNG was successfully saved.
    static func saveIfChanged(_ image: CGImage, previous: [Float]?, url: URL) throws -> [Float]? {
        try Task.checkCancellation()
        guard let fingerprint = fingerprint(image) else { return nil }
        if let previous, previous.count == fingerprint.count {
            let difference = zip(fingerprint, previous).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
                / Float(fingerprint.count)
            guard difference > 0.04 else { return nil }
        }
        try Task.checkCancellation()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try Task.checkCancellation()
        try png.write(to: url, options: .atomic)
        return fingerprint
    }

    /// Drawing may decode the source image, so even this small fingerprint
    /// belongs on the worker along with PNG encoding.
    private static func fingerprint(_ image: CGImage) -> [Float]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels.map { Float($0) / 255 } : nil
    }
}
