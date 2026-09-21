import AppKit

struct MeetingSlide: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var capturedAt: Date?
    var offset: TimeInterval?
    var automatic: Bool = true
    var id: String { path }
    var timestamp: String { offset.map { MeetingSource.stamp($0) } ?? "Time unavailable" }
}

/// Only completed, persisted files belong to the meeting. Session tokens
/// prevent late work from changing the next recording.
@MainActor
final class MeetingSlideCapture: ObservableObject {
    typealias Writer = @Sendable (CGImage, [Float]?, URL) throws -> [Float]?
    enum Result: Equatable {
        case saved(MeetingSlide), unchanged, busy, noWindow, limit, failed, cancelled
    }
    private struct Session {
        let token = UUID()
        let meetingID: String
        let folder: URL
        let startedAt: Date
    }
    var onChange: (String, [MeetingSlide]) throws -> Void = { _, _ in }
    private let writer: Writer
    private let removeFile: (URL) throws -> Void
    private let automaticLimit: Int
    private var session: Session?
    @Published private(set) var busy = false
    @Published private(set) var slides: [MeetingSlide] = []
    var paths: [String] { slides.map(\.path) }
    private var pendingWrite: Task<[Float]?, Never>?
    private var lastFingerprint: [Float]?
    private var nextIndex = 0

    init(removeFile: @escaping (URL) throws -> Void = {
        if FileManager.default.fileExists(atPath: $0.path) {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    }, automaticLimit: Int = 120, writer: @escaping Writer = { image, previous, url in
        try MeetingSlideWriter.saveIfChanged(image, previous: previous, url: url)
    }) {
        self.writer = writer
        self.removeFile = removeFile
        self.automaticLimit = automaticLimit
    }

    func start(meetingID: String, folder: URL, startedAt: Date = Date(), slides: [MeetingSlide] = []) {
        _ = finish()
        session = Session(meetingID: meetingID, folder: folder, startedAt: startedAt)
        self.slides = slides
    }

    func finish() -> [String] {
        session = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        busy = false
        lastFingerprint = nil
        nextIndex = 0
        let saved = paths
        slides = []
        return saved
    }

    func remove(path: String, meetingID: String) throws {
        guard session?.meetingID == meetingID, slides.contains(where: { $0.path == path }) else { return }
        let remaining = slides.filter { $0.path != path }
        try onChange(meetingID, remaining)
        do { try removeFile(URL(fileURLWithPath: path)) }
        catch { try onChange(meetingID, slides); throw error }
        slides = remaining
        // Keep the last fingerprint so the next automatic tick does not
        // immediately re-add the unchanged image the user just removed.
    }

    @discardableResult
    func capture(meetingID: String, force: Bool = false, now: () -> Date = Date.init,
                 image: () async -> CGImage?, inspect: (CGImage) async -> Void) async -> Result {
        guard let session, session.meetingID == meetingID else { return .cancelled }
        guard !busy else { return .busy }
        busy = true
        defer {
            if self.session?.token == session.token { busy = false; pendingWrite = nil }
        }
        guard let image = await image() else { return .noWindow }
        let capturedAt = now()
        guard self.session?.token == session.token else { return .cancelled }
        await inspect(image)
        guard self.session?.token == session.token else { return .cancelled }
        guard force || slides.filter(\.automatic).count < automaticLimit else { return .limit }

        // Each attempt has its own name, including after deletion or a
        // restarted session. Never derive a destination from the array count.
        let url = session.folder.appendingPathComponent("\(meetingID)-slide-\(nextIndex)-\(UUID().uuidString).png")
        nextIndex += 1
        let previous = force ? nil : lastFingerprint
        let writer = self.writer
        let work = Task.detached(priority: .utility) {
            autoreleasepool { try? writer(image, previous, url) }
        }
        pendingWrite = work
        let fingerprint = await work.value
        guard self.session?.token == session.token else {
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
            return .cancelled
        }
        guard let fingerprint else { return force ? .failed : .unchanged }
        let slide = MeetingSlide(path: url.path, capturedAt: capturedAt,
                                 offset: max(0, capturedAt.timeIntervalSince(session.startedAt)), automatic: !force)
        do { try onChange(meetingID, slides + [slide]) }
        catch {
            try? FileManager.default.removeItem(at: url)
            return .failed
        }
        lastFingerprint = fingerprint
        slides.append(slide)
        return .saved(slide)
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
