import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

enum DictationProfile {
    static var language: String { UserDefaults.standard.string(forKey: "dictationLanguage") ?? "en" }
    static var microphoneUID: String { UserDefaults.standard.string(forKey: "microphoneUID") ?? "" }
    static let languages: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("pt", "Portuguese"), ("it", "Italian"), ("nl", "Dutch"), ("ja", "Japanese"),
        ("zh", "Chinese"), ("ko", "Korean"), ("hi", "Hindi"), ("ar", "Arabic"),
        ("ru", "Russian"), ("pl", "Polish"), ("sv", "Swedish"), ("tr", "Turkish")
    ]
    // NVIDIA's parakeet-tdt-0.6b-v3 model card. Other languages use Qwen.
    static let parakeetLanguages: Set<String> = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    static func locale(for language: String) -> Locale {
        let locales = ["en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "pt": "pt-BR", "it": "it-IT",
                       "nl": "nl-NL", "ja": "ja-JP", "zh": "zh-CN", "ko": "ko-KR", "hi": "hi-IN", "ar": "ar-SA",
                       "ru": "ru-RU", "pl": "pl-PL", "sv": "sv-SE", "tr": "tr-TR"]
        return Locale(identifier: locales[language] ?? language)
    }
    static func deviceID(for uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: CFString = "" as CFString
            var valueSize = UInt32(MemoryLayout<CFString>.size)
            return AudioObjectGetPropertyData(device, &property, 0, nil, &valueSize, &value) == noErr && value as String == uid
        }
    }
}

enum DictationLatency {
    struct Sample: Codable {
        var recognition: Int; var cleanup: Int; var delivery: Int; var total: Int
    }
    static var samples: [Sample] {
        guard let data = UserDefaults.standard.data(forKey: "dictationLatencySamples") else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }
    static func record(recognition: Int, cleanup: Int, delivery: Int, total: Int) {
        let next = Array((samples + [Sample(recognition: recognition, cleanup: cleanup, delivery: delivery, total: total)]).suffix(50))
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: "dictationLatencySamples") }
    }
    static func percentile(_ values: [Int], fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[min(values.count - 1, max(0, Int(ceil(Double(values.count) * fraction)) - 1))]
    }
}

struct DictationProfileSettings: View {
    @AppStorage("dictationLanguage") private var language = "en"
    @AppStorage("dictationEngineProfile") private var engine = "auto"
    @AppStorage("microphoneUID") private var microphone = ""
    @State private var devices: [AVCaptureDevice] = []
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Picker("Language", selection: $language) {
                ForEach(DictationProfile.languages, id: \.0) { Text($0.1).tag($0.0) }
            }.clickable()
            Picker("Recognition", selection: $engine) {
                Text("Automatic").tag("auto")
                Text("Fast · Parakeet").tag("parakeet").disabled(!DictationProfile.parakeetLanguages.contains(language))
                Text("Accurate · Qwen3").tag("qwen3").disabled(!SttEngineKind.qwen3.isAvailable)
                if SttEngineKind.apple.isAvailable { Text("Apple Speech").tag("apple") }
            }.clickable()
            Text("Non-English dictation skips English cleanup. Qwen supports every language listed; Parakeet is available for its supported European languages. Apple support depends on installed language assets.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            Picker("Microphone", selection: $microphone) {
                Text("System default").tag("")
                ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                if !microphone.isEmpty, !devices.contains(where: { $0.uniqueID == microphone }) { Text("Saved microphone unavailable").tag(microphone) }
            }.clickable()
            Text("Applied to the next capture when the microphone is idle. An unavailable device falls back to the system default.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
            let samples = DictationLatency.samples
            if !samples.isEmpty {
                Text("Last \(samples.count) dictations · release to result: median \(DictationLatency.percentile(samples.map(\.total), fraction: 0.5)) ms · p95 \(DictationLatency.percentile(samples.map(\.total), fraction: 0.95)) ms")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
        }.task { devices = AVCaptureDevice.devices(for: .audio) }
    }
}
