import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// THE mic pipeline — one engine, one tap, any number of consumer sessions.
/// Two AVAudioEngines with voice processing on one input is a CoreAudio
/// crash (dictation during a meeting), and our voice-processing unit +
/// engine churn audibly degraded the mic OTHER apps heard mid-call. So:
/// meetings capture .raw (Zoom's processing is left alone, engine never
/// restarts mid-recording); dictation gets voice processing only while no
/// raw session is active. Always the system-default input.
final class AudioCapture: @unchecked Sendable {
    static let shared = AudioCapture()

    enum Mode { case voiceProcessed, raw }

    private var engine: AVAudioEngine?
    private var vpEnabled = false
    private var tapInstalled = false
    private var buffers: [UUID: [Float]] = [:]
    private var modes: [UUID: Mode] = [:]
    private let lock = NSLock()

    /// Build the engine once and keep it — creating AVAudioEngine and
    /// enabling voice processing costs 100-300ms, which is exactly the lag
    /// between hotkey and pill that Wispr doesn't have.
    private let prepareLock = NSLock()

    func prepare() {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        guard engine == nil else { return }
        let eng = AVAudioEngine()
        // Voice processing (AGC + noise suppression) lifts whispers for the
        // dictation model. Best-effort — plain capture if hardware refuses.
        if !suppressVoiceProcessing {
            try? eng.inputNode.setVoiceProcessingEnabled(true)
            vpEnabled = true
        } else {
            vpEnabled = false
        }
        _ = eng.inputNode.outputFormat(forBus: 0) // force graph configuration
        eng.prepare()
        engine = eng
    }

    /// TRUE while a screen recording runs. An INITIALIZED voice-processing
    /// unit — even on a prepared engine that never started — flips macOS
    /// into voice-chat mode: system audio output is ducked to near-silence
    /// and the mic goes through AEC. In a screen recording that's a faint
    /// system track with whistle artifacts on top, and SCK's own mic
    /// capture loses the fight entirely (no mic track written).
    var suppressVoiceProcessing = false {
        didSet {
            guard suppressVoiceProcessing != oldValue else { return }
            if suppressVoiceProcessing {
                releaseIfIdle()
            } else {
                // Re-warm off the caller's thread — VP setup blocks 100ms+.
                DispatchQueue.global(qos: .utility).async { self.prepare() }
            }
        }
    }

    /// Tear the warm engine down when nothing is capturing — the only way
    /// to fully exit voice-chat mode is to destroy the VP unit.
    func releaseIfIdle() {
        lock.lock()
        let idle = buffers.isEmpty
        lock.unlock()
        guard idle else { return }
        prepareLock.lock()
        defer { prepareLock.unlock() }
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        vpEnabled = false
    }

    /// Start a capture session. The engine starts on the first session and
    /// reconfigures only when the required processing mode changes.
    func begin(_ mode: Mode) throws -> UUID {
        let id = UUID()
        lock.lock()
        buffers[id] = []
        modes[id] = mode
        lock.unlock()
        try reconfigureAndRun()
        return id
    }

    /// Atomically take this session's accumulated audio (processed, 16kHz)
    /// WITHOUT touching the engine — the periodic meeting drain.
    func drain(_ id: UUID) -> [Float] {
        let rate = engine?.inputNode.inputFormat(forBus: 0).sampleRate ?? 48000
        lock.lock()
        let raw = buffers[id] ?? []
        buffers[id] = []
        lock.unlock()
        return Self.finalize(raw, sampleRate: rate)
    }

    /// End a session: final drain, then stop the engine only when it was the
    /// last session (a remaining session may flip processing mode back).
    func end(_ id: UUID) -> [Float] {
        let rate = engine?.inputNode.inputFormat(forBus: 0).sampleRate ?? 48000
        lock.lock()
        let raw = buffers.removeValue(forKey: id) ?? []
        modes.removeValue(forKey: id)
        let remaining = buffers.count
        lock.unlock()
        if remaining == 0 {
            if tapInstalled {
                engine?.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine?.stop() // engine object stays warm for the next take
        } else {
            try? reconfigureAndRun()
        }
        return Self.finalize(raw, sampleRate: rate)
    }

    /// RMS level of a session's most recent ~`window` seconds, 0...1-ish.
    /// Cheap — safe to poll at 10Hz for pill waveforms.
    func currentLevel(for id: UUID, window: Double = 0.1) -> Float {
        guard let eng = engine else { return 0 }
        let rate = eng.inputNode.inputFormat(forBus: 0).sampleRate
        let n = max(1, Int(rate * window))
        lock.lock()
        let tail = (buffers[id] ?? []).suffix(n)
        lock.unlock()
        guard !tail.isEmpty else { return 0 }
        let sumSquares = tail.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(tail.count))
    }

    /// Any raw session (a meeting) forces voice processing OFF for everyone —
    /// the call app owns echo cancellation; ours corrupts what peers hear.
    private func desiredVoiceProcessing() -> Bool {
        if suppressVoiceProcessing { return false }
        lock.lock()
        defer { lock.unlock() }
        return !modes.values.contains(.raw)
    }

    private func reconfigureAndRun() throws {
        prepare()
        let wantVP = desiredVoiceProcessing()
        if let eng = engine, eng.isRunning, wantVP == vpEnabled, tapInstalled { return }
        // Toggling voice processing on a prepared engine is a CoreAudio
        // crash farm (the dictation-during-meeting deaths) — REBUILD instead.
        if wantVP != vpEnabled || engine == nil {
            if tapInstalled {
                engine?.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine?.stop()
            let eng = AVAudioEngine()
            try? eng.inputNode.setVoiceProcessingEnabled(wantVP)
            vpEnabled = wantVP
            _ = eng.inputNode.outputFormat(forBus: 0)
            eng.prepare()
            engine = eng
        }
        guard let eng = engine else { return }
        if !tapInstalled {
            // Record at native format (float32); resample at drain/end.
            eng.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                guard let self, let floatData = buf.floatChannelData else { return }
                let frameCount = Int(buf.frameLength)
                var chunk = [Float](repeating: 0, count: frameCount)
                for i in 0..<frameCount {
                    chunk[i] = floatData[0][i]
                }
                self.lock.lock()
                for key in self.buffers.keys {
                    self.buffers[key]?.append(contentsOf: chunk)
                }
                self.lock.unlock()
            }
            tapInstalled = true
        }
        if !eng.isRunning { try eng.start() }
    }

    /// Bundle IDs of processes currently holding the mic open (macOS 14.4+
    /// CoreAudio process objects; empty when attribution is unavailable).
    /// Used by meeting detection AND to decide dictation's processing mode —
    /// if a call app owns the mic, our voice processing corrupts what the
    /// other side hears, so we must join raw.
    static func processesUsingMic() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        var ids: [String] = []
        for object in objects {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr
            else { continue }
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundle = app.bundleIdentifier {
                ids.append(bundle)
            }
        }
        return ids
    }

    /// Peak-normalize up to a healthy level (this is what makes a whispered
    /// take hit the model at full strength), then resample to 16kHz.
    private static func finalize(_ raw: [Float], sampleRate: Double) -> [Float] {
        var raw = raw
        let peak = raw.map(abs).max() ?? 0
        if peak > 0.0003, peak < 0.85 {
            let gain = 0.9 / peak
            for i in raw.indices { raw[i] *= gain }
        }
        return resample(raw, from: sampleRate, to: 16000)
    }

    static func resample(_ raw: [Float], from nativeRate: Double, to targetRate: Double) -> [Float] {
        if abs(nativeRate - targetRate) < 1 { return raw }
        // Prefer AVAudioConverter (proper anti-aliased resampling); the linear
        // interpolation below is only the last-resort fallback.
        if let converted = converterResample(raw, from: nativeRate, to: targetRate) {
            return converted
        }
        let ratio = nativeRate / targetRate
        let dstCount = Int(Double(raw.count) / ratio)
        guard dstCount > 0 else { return [] }
        var resampled = [Float](repeating: 0, count: dstCount)
        for i in 0..<dstCount {
            let srcIdx = min(Double(i) * ratio, Double(raw.count - 1))
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = raw[idx0]
            let s1 = idx0 + 1 < raw.count ? raw[idx0 + 1] : s0
            resampled[i] = s0 + frac * (s1 - s0)
        }
        return resampled
    }

    private static func converterResample(_ raw: [Float], from nativeRate: Double,
                                          to targetRate: Double) -> [Float]? {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: nativeRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                              frameCapacity: AVAudioFrameCount(raw.count))
        else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(raw.count)
        raw.withUnsafeBufferPointer { ptr in
            inBuffer.floatChannelData![0].update(from: ptr.baseAddress!, count: raw.count)
        }
        let capacity = AVAudioFrameCount(Double(raw.count) * targetRate / nativeRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard error == nil, outBuffer.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0],
                                         count: Int(outBuffer.frameLength)))
    }
}
