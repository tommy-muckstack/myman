import Foundation
import Sentry

// Crash + hang reporting (Sentry project muckstack/myman). Complements
// analytics: they answer "what do people use", Sentry answers "why did it
// die on a machine I can't see". Same privacy rules — never attach note
// text, transcripts, or file paths.
//
// The DSN is not in this repo — official builds inject MMSentryDSN into
// Info.plist from the maintainer's gitignored secrets.env; source builds
// have no DSN and report nothing.

enum CrashReporting {
    static func setup() {
        let dsn = (Bundle.main.infoDictionary?["MMSentryDSN"] as? String) ?? ""
        guard dsn.hasPrefix("https://") else { return } // no key injected
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment =
                (Bundle.main.infoDictionary?["MMChannel"] as? String) ?? "dev"
            options.releaseName = "myman@\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")+\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")"
            // "Not responding" is as bad as crashing for a hotkey app.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 3
            // Crashes and hangs only — no tracing/session-replay payloads.
            options.tracesSampleRate = 0
        }
    }
}
