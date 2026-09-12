import AppKit
import SwiftUI
import GRDB

struct CapturePrivacySettings: View {
    @AppStorage("automaticCaptureThemes") private var automaticThemes = true
    @AppStorage("captureSemanticSearch") private var semanticSearch = true
    @AppStorage("captureWindowMetadata") private var windowMetadata = false
    @AppStorage("captureMetadataExcludedApps") private var excludedApps = ""
    @AppStorage("agentActionsEnabled") private var agentActions = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Allow local agents to use My Man tools", isOn: $agentActions).clickable()
            Text("Agents running under your Mac login can explicitly capture, edit, read, copy and delete through the local CLI or MCP tools. macOS permissions still apply. Turn this off to disable app actions; exported Brain files remain readable.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Toggle("Automatically group related captures into Themes", isOn: $automaticThemes)
                .onChange(of: automaticThemes) { _, _ in CaptureEnrichment.shared.schedule() }
            Toggle("Find similar meanings with on-device search", isOn: $semanticSearch)
                .onChange(of: semanticSearch) { _, enabled in
                    Task.detached(priority: .utility) {
                        try? await Database.shared.write { db in
                            if !enabled {
                                try db.execute(sql: "UPDATE captureChunk SET embedding = NULL; UPDATE note SET embedding = NULL; UPDATE screenshot SET embedding = NULL")
                            }
                            try db.execute(sql: "INSERT OR IGNORE INTO capturePending SELECT id FROM captureItem WHERE excluded = 0")
                        }
                        SearchService.clearVectorCache(); CaptureEnrichment.shared.schedule()
                    }
                }
            Toggle("Include app and window details with screenshots", isOn: $windowMetadata)
                .clickable()
                .onChange(of: windowMetadata) { _, enabled in
                    if !enabled {
                        Task.detached(priority: .utility) {
                            try? await Database.shared.write { db in
                                try ScreenshotContext.clearWindowDetails(in: db)
                            }
                        }
                    }
                }
            if windowMetadata {
                TextField("Exclude apps (names or bundle IDs, separated by commas)", text: $excludedApps)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: excludedApps) { _, value in
                        Task.detached(priority: .utility) { try? await Database.shared.write { try ScreenshotContext.clearWindowDetails(excludedApps: value, in: $0) } }
                    }
                Text("Only the selected window at capture time. Browser URLs are included when available through existing Accessibility access; query strings are omitted.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            Text("Text recognition, search, titles and Themes run on this Mac. These features use only items you capture or create in Man. They do not monitor your activity.")
                .foregroundStyle(MM.Colors.textSecondary)
            Text("In Search, right-click a capture to hide it from search and Themes or delete it. The filter menu lets you include hidden captures.")
                .foregroundStyle(MM.Colors.textSecondary)
            Button("Clear capture history…", role: .destructive) {
                let alert = NSAlert(); alert.messageText = "Clear all capture history?"
                alert.informativeText = "This deletes notes, dictations, meetings, screenshots and recordings, including local indexes and themes. Media moves to Trash. Current Brain exports are removed; earlier Git history and backups may remain."
                alert.addButton(withTitle: "Clear History"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { CaptureActions.perform { try CaptureLifecycle.clearHistory() } }
            }.clickable()
            Text("Deleting removes local derived data and current Brain exports. Files in Trash, older Brain Git revisions and your own backups can retain copies.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge)
    }
}
