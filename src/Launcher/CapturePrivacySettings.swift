import SwiftUI
import GRDB

struct CapturePrivacySettings: View {
    @AppStorage("automaticCaptureThemes") private var automaticThemes = true
    @AppStorage("captureSemanticSearch") private var semanticSearch = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Text("Text recognition, search, titles and Themes run on this Mac. These features use only items you capture or create in Man. They do not monitor your activity or collect app/window metadata.")
                .foregroundStyle(MM.Colors.textSecondary)
            Text("In History, right-click a capture to hide it from search and Themes or delete it. The ••• menu includes hidden captures and Clear History.")
                .foregroundStyle(MM.Colors.textSecondary)
            Text("Deleting removes local derived data and current Brain exports. Files in Trash, older Brain Git revisions and your own backups can retain copies.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge)
    }
}
