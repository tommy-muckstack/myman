import Foundation

struct AudioEchoEvidence: Sendable {
    struct Window: Sendable { let start: Double; let end: Double; let correlation: Double; let lag: Double }
    let windows: [Window]
    static let none = AudioEchoEvidence(windows: [])
    func supportsEcho(at time: Double) -> Bool {
        windows.contains { time >= $0.start && time <= $0.end && $0.correlation >= 0.55 }
    }

    /// RMS envelopes tolerate speaker/microphone filtering. Search a bounded
    /// lag separately per minute: capture clocks can drift over a long session.
    /// This is supporting evidence only; textual agreement is also required.
    static func analyze(micPath: String?, systemPath: String?) async -> AudioEchoEvidence {
        guard let micPath, let systemPath else { return .none }
        return await Task.detached(priority: .utility) {
            let mic = envelope(path: micPath), system = envelope(path: systemPath)
            guard min(mic.count, system.count) >= 100 else { return .none }
            var windows: [Window] = []
            for start in stride(from: 0, to: min(mic.count, system.count), by: 1200) {
                let count = min(1200, mic.count - start, system.count - start)
                guard count >= 100 else { break }
                var best = -1.0; var bestLag = 0
                for lag in -200...200 {
                    guard start + lag >= 0, start + lag + count <= system.count else { continue }
                    let value = correlation(mic, system, start: start, lag: lag, count: count)
                    if value > best { best = value; bestLag = lag }
                }
                windows.append(Window(start: Double(start) / 20, end: Double(start + count) / 20,
                                      correlation: best, lag: Double(bestLag) / 20))
            }
            return AudioEchoEvidence(windows: windows)
        }.value
    }

    static func correlation(_ a: [Double], _ b: [Double], start: Int, lag: Int, count: Int) -> Double {
        var sx = 0.0, sy = 0.0, xx = 0.0, yy = 0.0, xy = 0.0
        for i in 0..<count {
            let x = a[start + i], y = b[start + lag + i]
            sx += x; sy += y; xx += x * x; yy += y * y; xy += x * y
        }
        let n = Double(count), denominator = sqrt(max(0, (n * xx - sx * sx) * (n * yy - sy * sy)))
        return denominator > 1e-12 ? (n * xy - sx * sy) / denominator : 0
    }

    private static func envelope(path: String) -> [Double] {
        guard let file = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? file.close() }
        try? file.seek(toOffset: 44)
        var result: [Double] = []
        while let data = try? file.read(upToCount: 800 * 2 * 1000), !data.isEmpty {
            data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                for start in stride(from: 0, through: values.count - min(values.count, 800), by: 800) {
                    guard start + 800 <= values.count else { break }
                    var sum = 0.0
                    for i in start..<(start + 800) { let x = Double(values[i]) / 32768; sum += x * x }
                    result.append(sqrt(sum / 800))
                }
            }
        }
        return result
    }
}
