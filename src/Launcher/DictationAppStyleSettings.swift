import SwiftUI

struct DictationAppStyleSettings: View {
    @State private var bundle = ""
    @State private var tone = "default"
    @State private var saved = false
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    var body: some View {
        DisclosureGroup("Style for a specific app") {
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                Picker("App", selection: $bundle) {
                    Text("Choose a running app").tag("")
                    ForEach(applications, id: \.processIdentifier) { app in Text(app.localizedName ?? app.bundleIdentifier!).tag(app.bundleIdentifier!) }
                }.clickable().onChange(of: bundle) { _, value in tone = (UserDefaults.standard.dictionary(forKey: "dictationAppStyles")?[value] as? String) ?? "default"; saved = false }
                Picker("Writing style", selection: $tone) { Text("Use default").tag("default"); ForEach(DictationTone.allCases) { Text($0.label).tag($0.rawValue) } }.clickable()
                Button("Save app style") { DictationAppStyles.set(DictationTone(rawValue: tone), for: bundle); saved = true }.disabled(bundle.isEmpty).clickable()
                if saved { Text("Saved for this app.").font(MM.Fonts.metadata) }
            }
        }.clickable()
    }
}
