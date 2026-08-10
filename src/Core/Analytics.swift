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
            // Which Mac. One person running two machines looks like two users
            // otherwise, and every "is this a real user or just me?" question
            // needs telling them apart.
            "machine": machineName,
            "device_model": deviceModel,
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

    /// A human-recognisable name for this Mac. `localizedName` is documented
    /// as optional and does come back empty in practice, so fall back to the
    /// host name rather than collapsing every such machine into "unknown" —
    /// two machines both called "unknown" are indistinguishable, which is the
    /// exact failure this property exists to prevent.
    private static var machineName: String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        let host = ProcessInfo.processInfo.hostName
        let trimmed = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// The hardware identifier, e.g. "Mac16,8". Always present, never renamed
    /// by the user, and the SAME string Sentry reports — which is what lets a
    /// crash be lined up against its analytics.
    private static var deviceModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &chars, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: chars)
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
