import Foundation

/// Finished phrases are recognized while the person is still talking, so
/// releasing the hotkey only leaves the last few seconds to decode. A phrase
/// is cut only inside a real pause — never mid-word — and long unbroken
/// speech is cut at its quietest moment, like long takes always were.
enum DictationSegmenter {
    static let frameSeconds = 0.02

    /// Sample index (into `raw`) where the latest finished phrase ends, or nil
    /// while no pause has closed one yet.
    static func cut(in raw: [Float], sampleRate: Double, minSpeech: Double = 4, pause: Double = 0.45,
                    maxSegment: Double = 25) -> Int? {
        let frame = max(1, Int(sampleRate * frameSeconds))
        guard raw.count >= Int(sampleRate * (minSpeech + pause)) else { return nil }
        let frames = raw.count / frame
        var energy = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        for index in 0..<frames {
            var sum: Float = 0
            for sample in raw[(index * frame)..<((index + 1) * frame)] { sum += sample * sample; peak = max(peak, abs(sample)) }
            energy[index] = (sum / Float(frame)).squareRoot()
        }
        guard peak > 0.01 else { return nil }
        let quiet = max(Float(0.0035), peak * 0.08)
        let needed = Int(pause / frameSeconds)
        let earliest = Int(minSpeech / frameSeconds)
        // The newest audio may be a pause that is still growing; leave the
        // last 0.2 s alone so a cut never lands on a word that is starting.
        let latest = frames - Int(0.2 / frameSeconds)
        var best: Int?
        var run = 0
        var spoke = false
        for index in 0..<max(0, latest) {
            if energy[index] < quiet {
                run += 1
                if run >= needed, spoke, index - run / 2 >= earliest { best = index - run / 2 }
            } else {
                run = 0
                spoke = true
            }
        }
        if let best { return best * frame }
        // No pause in a long stretch: the quietest moment near the limit.
        guard Double(raw.count) / sampleRate >= maxSegment else { return nil }
        let start = Int((maxSegment - 8) / frameSeconds), end = min(latest, Int(maxSegment / frameSeconds))
        guard start < end, let quietest = (start..<end).min(by: { energy[$0] < energy[$1] }) else { return nil }
        return quietest * frame + frame / 2
    }
}
