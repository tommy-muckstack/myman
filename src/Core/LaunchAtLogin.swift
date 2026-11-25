import Foundation
import ServiceManagement

/// Opens My Man when the person logs in. On by default for a new install: the first launch registers it once,
/// and after that the person's choice in Settings → General is what counts.
enum LaunchAtLogin {
    static let seededKey = "launchAtLoginSeeded"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Registers the login item the first time the app runs. Later launches leave the choice alone.
    static func seedDefaultOnce(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: seededKey) else { return }
        defaults.set(true, forKey: seededKey)
        guard Bundle.main.bundleURL.pathExtension == "app", !isEnabled else { return }
        try? set(true)
    }
}
