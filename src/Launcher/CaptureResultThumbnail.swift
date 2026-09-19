import AppKit
import AVFoundation
import GRDB
import SwiftUI

/// Small, local previews shared by history, search, and theme results.
struct CaptureResultThumbnail: View {
    let item: CaptureItem
    var database: DatabaseQueue? = nil
    @State private var image: NSImage?
    @State private var refresh = 0

    var body: some View {
        Group {
            if item.kind == "note" {
                NotePageThumbnail(title: item.title, text: item.body)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 72, height: 56)
                    .background(MM.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                    .overlay(alignment: .bottomTrailing) {
                        if item.kind == "recording" {
                            Image(systemName: "play.fill")
                                .font(MM.Fonts.gellix(10, .medium))
                                .foregroundStyle(MM.Colors.textPrimary)
                                .padding(4)
                                .background(MM.Colors.background, in: Circle())
                                .padding(3)
                        }
                    }
            } else {
                IconView(icon: item.icon, color: MM.Colors.textTertiary)
                    .frame(width: 72, height: 56)
                    .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            }
        }
        .frame(width: 72, height: 56)
        .accessibilityHidden(true)
        .task(id: "\(item.id):\(item.revision):\(item.sourcePath):\(refresh)") {
            image = nil
            guard ["screenshot", "meeting", "recording"].contains(item.kind) else { return }
            let worker = Task.detached(priority: .utility) {
                await CapturePreviewLoader.load(item, database: database)
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureLibraryChanged)) { _ in refresh += 1 }
    }
}

private struct NotePageThumbnail: View {
    let title: String
    let text: String

    var bodyText: String { MarkdownRich.plainText(String(text.prefix(1200))) }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text(title).font(MM.Fonts.gellix(22, .semiBold)).lineLimit(2)
            Text(bodyText).font(MM.Fonts.gellix(16)).lineLimit(8)
                .foregroundStyle(MM.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(MM.Colors.textPrimary)
        .padding(MM.Layout.padding)
        .frame(width: 176, height: 224, alignment: .topLeading)
        .background(MM.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 3))
        .scaleEffect(0.25)
        .frame(width: 44, height: 56)
    }
}

enum CapturePreviewLoader {
    static func load(_ item: CaptureItem, database: DatabaseQueue? = nil, size: Int = 160) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        switch item.kind {
        case "screenshot":
            return CaptureThumbnailCache.load(path: item.sourcePath, size: size)
        case "meeting":
            let paths = (try? await (database ?? Database.shared).read { db in
                try Meeting.fetchOne(db, key: item.sourceID)?.slidePaths ?? []
            }) ?? []
            for path in paths {
                guard !Task.isCancelled else { return nil }
                if let image = CaptureThumbnailCache.load(path: path, size: size) { return image }
            }
            return nil
        case "recording":
            guard !item.sourcePath.isEmpty,
                  let version = OCRStore.version(URL(fileURLWithPath: item.sourcePath)) else { return nil }
            let key = "video:\(item.sourcePath):\(version):\(size)" as NSString
            if let image = CaptureThumbnailCache.cache.object(forKey: key) { return image }
            let asset = AVURLAsset(url: URL(fileURLWithPath: item.sourcePath))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: size, height: size)
            let frame = await withTaskCancellationHandler {
                try? await generator.image(at: .zero)
            } onCancel: { generator.cancelAllCGImageGeneration() }
            guard !Task.isCancelled, let frame else { return nil }
            let image = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
            CaptureThumbnailCache.cache.countLimit = 160
            CaptureThumbnailCache.cache.setObject(image, forKey: key)
            return image
        default:
            return nil
        }
    }
}
