import Foundation

/// Incremental mono Int16 WAV writer (16kHz for ASR tracks by default,
/// native-rate for narration): writes a placeholder header, appends samples
/// as they arrive, and patches the true sizes on close. Keeps hour-long
/// recordings off the heap.
final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private let sampleRate: UInt32

    init?(url: URL, sampleRate: UInt32 = 16000) {
        self.sampleRate = sampleRate
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        try? handle.write(contentsOf: Self.header(dataSize: 0, sampleRate: sampleRate))
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32767)
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try? handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    /// Patch the header with the real sizes and close. Returns nil (deleting
    /// the file) if nothing was ever written.
    func close() -> URL? {
        defer { try? handle.close() }
        guard dataBytes > 0 else {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(dataSize: dataBytes, sampleRate: sampleRate))
        return url
    }

    /// Read a 16kHz mono Int16 WAV back into Float samples.
    static func readSamples(from url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return [] }
        let payload = data.dropFirst(44)
        var samples = [Float](repeating: 0, count: payload.count / 2)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                samples[i] = Float(int16Buffer[i]) / 32767.0
            }
        }
        return samples
    }

    private static func header(dataSize: UInt32, sampleRate: UInt32) -> Data {
        var data = Data()
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))              // PCM
        append(UInt16(1))              // mono
        append(sampleRate)
        append(sampleRate * 2)         // byte rate
        append(UInt16(2))              // block align
        append(UInt16(16))             // bits per sample
        data.append(contentsOf: "data".utf8)
        append(dataSize)
        return data
    }
}
