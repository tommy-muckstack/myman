import AmplitudeSwift
import Foundation

// Product analytics via Amplitude (org muck-stack, project "My Man").
// Curated snake_case taxonomy; properties are counts, kinds, and durations
// ONLY. Never send note text, transcripts, OCR content, queries, or file
// paths.
//
// The ingestion key is NOT in this repo: official builds inject
// MMAmplitudeKey into Info.plist from the maintainer's gitignored
// secrets.env. Builds without it (anyone building from source) send nothing.

enum Analytics {
    private static var amplitude: Amplitude?
    private static var commonProps: [String: Any] = [:]

    static func setup() {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let common: [String: Any] = [
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "dev",
            "app_build": info?["CFBundleVersion"] as? String ?? "0",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            // "release" only in build-direct.sh bundles — filter dashboards to
            // channel=release so dev runs never pollute install/upgrade counts.
            "channel": info?["MMChannel"] as? String ?? "dev",
        ]
        commonProps = common

        if let key = info?["MMAmplitudeKey"] as? String, !key.isEmpty {
            // App-lifecycle autocapture keeps install/upgrade/open visibility
            // (Application Installed / Updated / Opened events).
            let amp = Amplitude(configuration: Configuration(
                apiKey: key, logLevel: .WARN,
                autocapture: [.sessions, .appLifecycles]
            ))
            let identify = Identify()
            for (k, v) in common { _ = identify.set(property: k, value: v) }
            amp.identify(identify: identify)
            amplitude = amp
        }
    }

    static func track(_ event: String, _ properties: [String: Any] = [:]) {
        // Amplitude has no super properties for event props, so merge the
        // common set into every event (event props win). nil (no key
        // injected) means telemetry is off entirely.
        amplitude?.track(
            eventType: event,
            eventProperties: commonProps.merging(properties) { _, new in new }
        )
    }
}
