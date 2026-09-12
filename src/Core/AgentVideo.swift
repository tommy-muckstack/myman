import AppKit
import AVFoundation

/// Uses AVFoundation for local frame inspection, trimming and segment assembly.
/// Original recordings are never replaced by agent exports.
@MainActor enum AgentVideo {
    static func range(start: Double, end: Double?, duration: Double) throws -> CMTimeRange {
        let finish = end ?? duration
        guard start.isFinite, finish.isFinite, duration.isFinite, start >= 0, finish > start, finish <= duration + 0.001 else {
            throw AgentError("INVALID_ARGUMENTS", "Trim bounds must be inside the video, with end after start.")
        }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: min(finish, duration), preferredTimescale: 600))
    }
    static func sampleTimes(_ explicit: [Double]?, count: Int, duration: Double) throws -> [Double] {
        guard duration.isFinite, duration > 0, (1...12).contains(count) else { throw AgentError("INVALID_ARGUMENTS", "Use 1–12 frames from a nonempty video.") }
        let times = explicit ?? (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        guard !times.isEmpty, times.count <= 12, times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration }) else {
            throw AgentError("INVALID_ARGUMENTS", "Frame times must be inside the video (strictly before its end).")
        }
        return times
    }
    static func attachment(_ url: URL, preview: Bool = true) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AgentError("INVALID_VIDEO", "Recording has no playable video track.")
        }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        var result: [String: Any] = ["path": url.path, "mime_type": url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime",
                                     "width": Double(abs(bounds.width)), "height": Double(abs(bounds.height)), "duration": duration,
                                     "file_size": ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0, "preview_path": NSNull()]
        if preview {
            do {
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 512, height: 512)
                let (cg, _) = try await generator.image(at: CMTime(seconds: min(0.2, duration / 2), preferredTimescale: 600))
                let thumb = try AgentMediaStore.shared.image(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)), prefix: "video-thumbnail")
                result["preview_path"] = thumb["path"]; result["preview_expires_at"] = thumb["expires_at"]
            } catch { result["preview_status"] = "unavailable" }
        }
        return result
    }
    static func frames(_ url: URL, args: [String: Any], store suppliedStore: AgentMediaStore? = nil) async throws -> [String: Any] {
        let store = suppliedStore ?? .shared
        let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
        guard args["times"] == nil || args["count"] == nil else { throw AgentError("INVALID_ARGUMENTS", "Choose times or count.") }
        let countValue = args["count"] as? Double ?? 6
        let widthValue = args["width"] as? Double ?? 400
        guard countValue.rounded() == countValue, widthValue.rounded() == widthValue else { throw AgentError("INVALID_ARGUMENTS", "Count and width must be integers.") }
        let times = try sampleTimes(args["times"] as? [Double], count: Int(countValue), duration: duration)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: widthValue, height: widthValue)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        var images: [NSImage] = [], results: [[String: Any]] = []
        for time in times {
            let (cg, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            images.append(image)
            var result = try store.image(image, prefix: "frame")
            result["requested_time"] = time; result["actual_time"] = actual.seconds
            results.append(result)
        }
        let columns = min(3, images.count), rows = (images.count + columns - 1) / columns
        let cellWidth = CGFloat(widthValue), imageHeight = images.map { AgentImages.size($0).height }.max() ?? 1
        let cellHeight = imageHeight + 28
        let sheet = try AgentMediaStore.canvas(size: CGSize(width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)) { context in
            context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight))
            for (index, image) in images.enumerated() {
                let x = CGFloat(index % columns) * cellWidth, y = CGFloat(rows - 1 - index / columns) * cellHeight
                let size = AgentImages.size(image)
                image.draw(in: CGRect(x: x + (cellWidth - size.width) / 2, y: y + 28, width: size.width, height: size.height))
                let label = String(format: "%.2fs", results[index]["actual_time"] as? Double ?? times[index])
                (label as NSString).draw(at: CGPoint(x: x + 8, y: y + 7), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
            }
        }
        return ["frames": results, "contact_sheet": try store.image(sheet, prefix: "contact-sheet"), "duration": duration]
    }
    static func export(_ url: URL, to destination: URL, start: Double = 0, end: Double? = nil, maxBytes: Int? = nil) async throws {
        let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
        let selected = try range(start: start, end: end, duration: duration)
        // Try full quality first. A cap permits reducing resolution, but never
        // truncating duration via AVAssetExportSession.fileLengthLimit.
        let presets = maxBytes == nil ? [AVAssetExportPresetHighestQuality] : [AVAssetExportPresetHighestQuality, AVAssetExportPreset1280x720, AVAssetExportPreset640x480]
        for preset in presets {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset), exporter.supportedFileTypes.contains(.mp4) else { continue }
            exporter.outputURL = destination; exporter.outputFileType = .mp4
            exporter.timeRange = selected; exporter.shouldOptimizeForNetworkUse = true
            await exporter.export()
            guard exporter.status == .completed else {
                try? FileManager.default.removeItem(at: destination)
                throw AgentError("EXPORT_FAILED", exporter.error?.localizedDescription ?? "Video export failed.")
            }
            let bytes = ((try FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.intValue ?? 0
            if maxBytes == nil || bytes <= maxBytes! { return }
            try FileManager.default.removeItem(at: destination)
        }
        throw AgentError("SIZE_LIMIT_EXCEEDED", "The complete clip cannot fit at supported quality. Increase max_bytes or shorten the trim range.")
    }
    static func join(_ urls: [URL], to destination: URL) async throws {
        guard !urls.isEmpty else { throw AgentError("INVALID_VIDEO", "No recorded segments.") }
        let composition = AVMutableComposition()
        var targets: [AVMediaType: [AVMutableCompositionTrack]] = [:]
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url), duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw AgentError("INVALID_VIDEO", "An empty recording segment cannot be joined.") }
            for type in [AVMediaType.video, .audio] {
                for (index, source) in try await asset.loadTracks(withMediaType: type).enumerated() {
                    var tracks = targets[type] ?? []
                    while tracks.count <= index {
                        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AgentError("EXPORT_FAILED", "Cannot allocate segment track.") }
                        tracks.append(track)
                    }
                    targets[type] = tracks
                    let sourceRange = try await source.load(.timeRange)
                    let available = CMTimeRangeGetIntersection(sourceRange, otherRange: CMTimeRange(start: .zero, duration: duration))
                    if available.duration.seconds > 0 { try tracks[index].insertTimeRange(available, of: source, at: CMTimeAdd(cursor, available.start)) }
                    if type == .video { tracks[index].preferredTransform = try await source.load(.preferredTransform) }
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw AgentError("EXPORT_FAILED", "Cannot join recording segments.") }
        exporter.outputURL = destination; exporter.outputFileType = .mov
        await exporter.export()
        guard exporter.status == .completed else { try? FileManager.default.removeItem(at: destination); throw AgentError("EXPORT_FAILED", exporter.error?.localizedDescription ?? "Segment assembly failed.") }
    }
}
