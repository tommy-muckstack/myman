import AppKit
import SwiftUI
import GRDB

/// Recents use the same enriched capture titles as Search and History.
struct ScreenshotRowDescription: Sendable {
    var title: String
    var detail: String
    var revision: Int

    static func make(shot: Screenshot, item: CaptureItem?, context: ScreenshotContext?) -> Self {
        let title = item?.title ?? ScreenshotIntelligence.title(text: shot.ocrText, lines: []).nilIfBlank
            ?? "Screenshot · " + shot.createdAt.formatted(date: .abbreviated, time: .shortened)
        let source = [context?.app ?? "", context.flatMap { URL(string: $0.url)?.host } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let description = context?.analysis.summary ?? ""
        let excerpt = shot.ocrText.components(separatedBy: .newlines).first {
            $0.caseInsensitiveCompare(title) != .orderedSame && ScreenshotIntelligence.usefulTitle($0)
        } ?? ""
        return Self(title: title, detail: source.nilIfBlank ?? description.nilIfBlank ?? excerpt.nilIfBlank ?? "Screenshot", revision: item?.revision ?? 0)
    }
}

struct RecentScreenshotContent: View {
    let shot: Screenshot
    @State private var metadata: ScreenshotRowDescription?
    @State private var refresh = 0
    var body: some View {
        let value = metadata ?? ScreenshotRowDescription.make(shot: shot, item: nil, context: nil)
        HStack(spacing: MM.Layout.spacing) {
            CaptureThumbnail(path: shot.path, revision: value.revision, width: 72, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.title).font(MM.Fonts.body).foregroundStyle(MM.Colors.textPrimary).lineLimit(1)
                Text(value.detail).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).lineLimit(1)
            }
        }
        .task(id: "\(shot.id):\(refresh)") {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? Database.shared.read { db in
                    ScreenshotRowDescription.make(shot: shot,
                        item: try CaptureItem.fetchOne(db, key: "shot-" + shot.id),
                        context: try ScreenshotContext.fetchOne(db, key: "shot-" + shot.id))
                }
            }.value
            guard !Task.isCancelled else { return }
            metadata = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in refresh += 1 }
    }
}

private extension String { var nilIfBlank: String? { isEmpty ? nil : self } }
