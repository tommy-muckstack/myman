import AppKit
import AVFoundation
import CoreVideo

/// The last step of `record polish` on the Mac: title and end cards on the
/// same backdrop as the video, and music under the recording's own audio.
/// Same recipe names and defaults as the Linux companion. Built-in tracks are
/// rendered by the `myman` companion (the same generator as Linux) and
/// arrive here as an audio file.
enum DemoFinish {
    struct Card: Equatable {
        var text: String
        var subtitle: String?
        var seconds: Double

        var json: [String: Any] {
            var out: [String: Any] = ["text": text, "seconds": seconds]
            if let subtitle { out["subtitle"] = subtitle }
            return out
        }
    }

    struct Music: Equatable {
        var file: String
        var track: String?
        var volume: Double?
        var fadeIn: Double = 1.5
        var fadeOut: Double = 2.5
        var duck = true
        var start: Double = 0

        var json: [String: Any] {
            var out: [String: Any] = ["fade_in": fadeIn, "fade_out": fadeOut, "duck": duck, "start": start]
            if let track { out["track"] = track } else { out["file"] = file }
            if let volume { out["volume"] = volume }
            return out
        }
    }

    /// A line of text shown over the recording between `start` and `end`
    /// (recording seconds, before any title card).
    struct Caption: Equatable {
        var text: String
        var start: Double
        var end: Double

        var json: [String: Any] { ["text": text, "start": start, "end": end] }
    }

    static let captionFade = 0.25

    /// Caption text size for a video this tall (the same rule as Linux).
    static func captionPoints(_ height: CGFloat) -> CGFloat { max(18, (height / 20).rounded()) }
    /// How much backdrop to add under the video so a caption fits there.
    static func captionBand(videoHeight: CGFloat, padding: CGFloat) -> CGFloat {
        let need = (captionPoints(videoHeight) * 4).rounded()
        return 2 * ceil(max(0, need - padding) / 2)
    }

    static let titleFadeIn = 0.4, titleFadeOut = 0.3, endFadeIn = 0.3, endFadeOut = 0.5
    static let fps: Int32 = 30

    /// Louder on its own, quieter under the recording's audio (as on Linux).
    static func volume(_ music: Music, recordingHasAudio: Bool) -> Double {
        music.volume ?? (recordingHasAudio ? 0.4 : 0.8)
    }

    static func hasAudio(_ movie: URL) async -> Bool {
        (try? await AVURLAsset(url: movie).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
    }

    // MARK: Cards

    /// The card's still: the backdrop gradient (slate when the video has no
    /// backdrop) with the headline and optional subtitle centred and sized to fit.
    static func cardImage(_ card: Card, size: CGSize, options: PolishOptions) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = CGRect(origin: .zero, size: size)
        if options.backdrop == .custom {
            options.customColor.setFill(); rect.fill()
        } else {
            let colors = options.backdrop.colors ?? BackdropStyle.slate.colors!
            NSGradient(starting: colors[0], ending: colors[1])?.draw(in: rect, angle: -35)
        }
        let big = fitted(card.text, start: max(20, min(size.width / 16, size.height / 7)), width: size.width * 0.86, bold: true)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: font(big, bold: true), .foregroundColor: NSColor.white]
        let title = NSAttributedString(string: card.text, attributes: titleAttributes)
        let titleSize = title.boundingRect(with: CGSize(width: size.width, height: size.height), options: [.usesLineFragmentOrigin]).size
        var subtitle: NSAttributedString?
        var subtitleSize = CGSize.zero
        if let text = card.subtitle {
            let small = fitted(text, start: max(14, big * 0.45), width: size.width * 0.86, bold: false)
            let s = NSAttributedString(string: text, attributes: [.font: font(small, bold: false), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            subtitle = s
            subtitleSize = s.boundingRect(with: CGSize(width: size.width, height: size.height), options: [.usesLineFragmentOrigin]).size
        }
        let gap = subtitle == nil ? 0 : big * 0.35
        let blockHeight = titleSize.height + gap + subtitleSize.height
        let top = (size.height + blockHeight) / 2
        title.draw(with: CGRect(x: (size.width - titleSize.width) / 2, y: top - titleSize.height, width: titleSize.width + 1, height: titleSize.height), options: [.usesLineFragmentOrigin])
        if let subtitle {
            subtitle.draw(with: CGRect(x: (size.width - subtitleSize.width) / 2, y: top - titleSize.height - gap - subtitleSize.height,
                                       width: subtitleSize.width + 1, height: subtitleSize.height), options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func font(_ size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "Gellix-Bold" : "Gellix-Regular", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Shrinks the point size until the longest line fits the width.
    private static func fitted(_ text: String, start: CGFloat, width: CGFloat, bold: Bool) -> CGFloat {
        var size = start
        let lines = text.components(separatedBy: "\n")
        while size > 12 {
            let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: font(size, bold: bold)]).width }.max() ?? 0
            if widest <= width { break }
            size -= 1
        }
        return size
    }

    /// Writes a short silent clip of the card with a fade in and out.
    static func writeCard(_ card: Card, fadeIn: Double, fadeOut: Double, size: CGSize, options: PolishOptions, to url: URL) async throws {
        guard let still = cardImage(card, size: size, options: options) else { throw AgentError("EXPORT_FAILED", "Could not draw the card.") }
        let width = Int(size.width), height = Int(size.height)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw AgentError("EXPORT_FAILED", "Could not start writing the card.") }
        writer.add(input)
        guard writer.startWriting() else { throw AgentError("EXPORT_FAILED", writer.error?.localizedDescription ?? "Could not start writing the card.") }
        writer.startSession(atSourceTime: .zero)
        let frames = max(1, Int((card.seconds * Double(fps)).rounded()))
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let t = Double(index) / Double(fps)
            let fadeInLevel = fadeIn > 0 ? t / fadeIn : 1
            let fadeOutLevel = fadeOut > 0 ? (card.seconds - t) / fadeOut : 1
            let level = CGFloat(max(0, min(1, min(fadeInLevel, fadeOutLevel))))
            guard let buffer = pixelBuffer(still, level: level, pool: adaptor.pixelBufferPool, width: width, height: height) else {
                throw AgentError("EXPORT_FAILED", "Could not draw a card frame.")
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
                throw AgentError("EXPORT_FAILED", writer.error?.localizedDescription ?? "Could not write a card frame.")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw AgentError("EXPORT_FAILED", writer.error?.localizedDescription ?? "Could not finish the card.") }
    }

    private static func pixelBuffer(_ still: CGImage, level: CGFloat, pool: CVPixelBufferPool?, width: Int, height: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) }
        if made == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &made)
        }
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(still, in: rect)
        if level < 1 {
            context.setFillColor(CGColor(gray: 0, alpha: 1 - level))
            context.fill(rect)
        }
        return buffer
    }

    // MARK: Captions

    /// Captions use Gellix SemiBold (bundled with the app), like Linux.
    private static func captionFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Gellix-SemiBold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// The caption's still: white Gellix on a soft, translucent, fully rounded
    /// pill with a gentle shadow (the same look as Linux).
    static func captionImage(_ caption: Caption, videoSize: CGSize) -> CGImage? {
        let lines = caption.text.components(separatedBy: "\n")
        var size = captionPoints(videoSize.height)
        while size > 12, (lines.map { ($0 as NSString).size(withAttributes: [.font: captionFont(size)]).width }.max() ?? 0) > videoSize.width * 0.86 { size -= 1 }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineSpacing = size * 0.15
        let text = NSAttributedString(string: caption.text, attributes: [.font: captionFont(size), .foregroundColor: NSColor.white, .paragraphStyle: style])
        let textSize = text.boundingRect(with: CGSize(width: videoSize.width, height: videoSize.height), options: [.usesLineFragmentOrigin]).size
        let padX = size * 0.95, padY = size * 0.6, shadow = size * 0.5
        let pillW = ceil(textSize.width + padX * 2), pillH = ceil(textSize.height + padY * 2)
        let width = Int(pillW + shadow * 2), height = Int(pillH + shadow * 2)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let pill = CGRect(x: shadow, y: shadow, width: pillW, height: pillH)
        let radius = min(pillH / 2, size * 1.1)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -shadow / 3), blur: shadow, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(srgbRed: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 0.66).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        context.restoreGState()
        text.draw(with: CGRect(x: pill.minX + padX, y: pill.minY + padY, width: textSize.width + 1, height: textSize.height), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Caption layers over the whole joined video. `offset` is where the
    /// recording starts (after the title card). `place` is the backdrop band
    /// under the video to centre captions in; without one they sit near the
    /// bottom of the picture. `textFor` is the recording's size, which sets
    /// the text size.
    static func captionLayers(_ captions: [Caption], renderSize: CGSize, offset: Double, length: Double, place: CGRect? = nil, textFor: CGSize? = nil) -> [CALayer] {
        let sizing = textFor ?? renderSize
        return captions.compactMap { caption -> CALayer? in
            let start = max(0, caption.start), end = min(length, caption.end)
            guard end > start, let image = captionImage(caption, videoSize: sizing) else { return nil }
            let layer = CALayer()
            let w = CGFloat(image.width), h = CGFloat(image.height)
            // Core Animation in a video composition has its origin at the bottom left.
            let y = place.map { $0.minY + ($0.height - h) / 2 } ?? renderSize.height * 0.05
            layer.frame = CGRect(x: renderSize.width / 2 - w / 2, y: y, width: w, height: h)
            layer.contents = image
            layer.opacity = 0
            let seconds = end - start
            let fade = min(captionFade, seconds / 2) / seconds
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [0, 1, 1, 0]
            show.keyTimes = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
            show.beginTime = AVCoreAnimationBeginTimeAtZero + offset + start
            show.duration = seconds
            show.isRemovedOnCompletion = false
            show.fillMode = .both
            layer.add(show, forKey: "show")
            return layer
        }
    }

    // MARK: Joining and music

    /// Joins title card, video, and end card, then lays the music under the
    /// recording's audio: trimmed from `start`, looped to the full length,
    /// faded in and out. Returns what was done for the result summary.
    static func finish(input: URL, to destination: URL, title: Card?, end: Card?, music: Music?, captions: [Caption] = [], captionPlace: CGRect? = nil, captionText: CGSize? = nil,
                       options: PolishOptions, work: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw AgentError("INVALID_VIDEO", "Missing video track.") }
        let size = try await sourceVideo.load(.naturalSize)
        let transform = try await sourceVideo.load(.preferredTransform)
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AgentError("EXPORT_FAILED", "Could not build the video.")
        }
        video.preferredTransform = transform
        var cursor = CMTime.zero

        func appendCard(_ card: Card, name: String, fadeIn: Double, fadeOut: Double) async throws {
            let url = work.appendingPathComponent("\(name).mov")
            try await writeCard(card, fadeIn: fadeIn, fadeOut: fadeOut, size: size, options: options, to: url)
            let clip = AVURLAsset(url: url)
            guard let track = try await clip.loadTracks(withMediaType: .video).first else { throw AgentError("EXPORT_FAILED", "The card has no video.") }
            let length = try await clip.load(.duration)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: cursor)
            cursor = CMTimeAdd(cursor, length)
        }

        if let title { try await appendCard(title, name: "title", fadeIn: titleFadeIn, fadeOut: titleFadeOut) }
        let videoStart = cursor
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: cursor)
        cursor = CMTimeAdd(cursor, duration)
        if let end { try await appendCard(end, name: "end", fadeIn: endFadeIn, fadeOut: endFadeOut) }
        let total = cursor

        if let sourceAudio, let voice = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try voice.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: videoStart)
        }
        var mix: AVMutableAudioMix?
        var level: Double?
        if let music {
            let musicAsset = AVURLAsset(url: URL(fileURLWithPath: music.file))
            guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else {
                throw AgentError("INVALID_ARGUMENTS", "recipe.music.file has no audio stream.")
            }
            let musicLength = try await musicAsset.load(.duration)
            let start = CMTime(seconds: music.start, preferredTimescale: 600)
            guard CMTimeCompare(musicLength, start) > 0 else { throw AgentError("INVALID_ARGUMENTS", "recipe.music.start is past the end of the music.") }
            guard let bed = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AgentError("EXPORT_FAILED", "Could not add the music.")
            }
            var at = CMTime.zero, from = start, pieces = 0
            while CMTimeCompare(at, total) < 0 && pieces < 1000 {
                let piece = CMTimeMinimum(CMTimeSubtract(total, at), CMTimeSubtract(musicLength, from))
                guard CMTimeCompare(piece, .zero) > 0 else { break }
                try bed.insertTimeRange(CMTimeRange(start: from, duration: piece), of: musicTrack, at: at)
                at = CMTimeAdd(at, piece); from = .zero; pieces += 1
            }
            let v = Float(volume(music, recordingHasAudio: sourceAudio != nil))
            level = Double(v)
            let seconds = total.seconds
            let fadeIn = min(music.fadeIn, seconds / 2), fadeOut = min(music.fadeOut, seconds / 2)
            let parameters = AVMutableAudioMixInputParameters(track: bed)
            if fadeIn > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            } else {
                parameters.setVolume(v, at: .zero)
            }
            if fadeOut > 0 {
                parameters.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: CMTime(seconds: seconds - fadeOut, preferredTimescale: 600), duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
            }
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            mix = audioMix
        }

        var videoComposition: AVMutableVideoComposition?
        var shown = 0
        if !captions.isEmpty {
            let made = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            let renderSize = made.renderSize
            let layers = captionLayers(captions, renderSize: renderSize, offset: videoStart.seconds, length: duration.seconds, place: captionPlace, textFor: captionText)
            if !layers.isEmpty {
                let parent = CALayer(), videoLayer = CALayer()
                parent.frame = CGRect(origin: .zero, size: renderSize)
                videoLayer.frame = parent.frame
                parent.addSublayer(videoLayer)
                layers.forEach(parent.addSublayer)
                made.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
                videoComposition = made
                shown = layers.count
            }
        }

        let presets = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        guard let preset = presets.first(where: { AVAssetExportSession.exportPresets(compatibleWith: composition).contains($0) }),
              let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AgentError("EXPORT_FAILED", "No export preset is available for this recording.")
        }
        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.audioMix = mix
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw AgentError("EXPORT_FAILED", exporter.error?.localizedDescription ?? "Video export failed.")
        }
        var done: [String: Any] = ["duration": (total.seconds * 100).rounded() / 100]
        if title != nil || end != nil {
            done["cards"] = ["title_seconds": title?.seconds ?? 0, "end_seconds": end?.seconds ?? 0, "video_starts_at": (videoStart.seconds * 100).rounded() / 100]
        }
        if let level { done["music_volume"] = level }
        if !captions.isEmpty { done["captions"] = shown }
        return done
    }
}
