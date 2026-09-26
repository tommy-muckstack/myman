import AppKit
import AVFoundation

/// `myman record polish` on the Mac: the same JSON recipe and names as the
/// Linux companion, rendered by the recording editor's own polish engine
/// (`RecordingPolish`). Unknown keys are errors, never ignored, and options
/// the Mac cannot render yet fail as UNSUPPORTED rather than being dropped.
enum AgentPolish {
    static let levels: [String: Double] = ["subtle": 1.4, "normal": 1.8, "strong": 2.4]
    static let cursorSizes: [String: Double] = ["normal": 1.5, "big": 2, "huge": 2.6]
    static let backdrops: [String: BackdropStyle] = ["dusk": .dusk, "ocean": .ocean, "meadow": .meadow, "slate": .slate]
    static let recipeKeys = ["zoom", "cursor", "background", "music", "title", "end"]
    static let zoomKeys = ["auto", "level", "ramp", "gap", "moments"]
    static let momentKeys = ["start", "end", "x", "y", "level"]
    static let cursorKeys = ["size", "smooth", "highlight", "ripple"]
    static let backgroundKeys = ["style", "color", "corner_radius", "padding", "shadow"]

    struct Moment: Equatable { var start: Double; var end: Double; var x: Double; var y: Double }

    struct Plan {
        var options: PolishOptions
        var zoom: Bool
        var autoZoom: Bool
        var level: Double
        var moments: [Moment]
        var cursor: Bool
        var cursorSize: Double
        var background: String?

        /// The recipe as it will be rendered, with defaults filled in.
        var recipe: [String: Any] {
            var out: [String: Any] = [:]
            if zoom {
                var z: [String: Any] = ["auto": autoZoom, "level": level]
                if !moments.isEmpty { z["moments"] = moments.map { ["start": $0.start, "end": $0.end, "x": $0.x, "y": $0.y] } }
                out["zoom"] = z
            }
            if cursor { out["cursor"] = ["size": cursorSize, "smooth": options.smoothCursor] }
            if let background {
                var b: [String: Any] = ["style": background, "corner_radius": Double(options.cornerRadius), "padding": Double(options.paddingFraction)]
                if background == "custom" { b["color"] = AgentPolish.hex(options.customColor) }
                out["background"] = b
            }
            return out
        }
    }

    /// JSON booleans only: on the Mac every NSNumber casts to Bool, so 0 and 1
    /// would otherwise pass as false and true.
    static func isBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    static func bool(_ value: Any?) -> Bool? { isBool(value) ? (value as? NSNumber)?.boolValue : nil }

    private static func fail(_ message: String) -> AgentError { AgentError("INVALID_ARGUMENTS", message) }
    private static func unsupported(_ what: String) -> AgentError {
        AgentError("UNSUPPORTED", "\(what) is not available in record polish on the Mac yet.", details: ["platform": "macos"])
    }

    private static func object(_ value: Any?, _ keys: [String], _ where_: String) throws -> [String: Any] {
        guard let dict = value as? [String: Any] else { throw fail("\(where_) must be a JSON object.") }
        if let extra = dict.keys.sorted().first(where: { !keys.contains($0) }) {
            throw fail("\(where_) has unknown key \(extra). Allowed: \(keys.joined(separator: ", ")).")
        }
        return dict
    }

    private static func number(_ value: Any?, _ lo: Double, _ hi: Double, _ name: String) throws -> Double {
        if isBool(value) { throw fail("\(name) must be a number from \(formatted(lo)) to \(formatted(hi)).") }
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n >= lo, n <= hi else {
            throw fail("\(name) must be a number from \(formatted(lo)) to \(formatted(hi)).")
        }
        return n
    }

    private static func formatted(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    /// A named size or a number, like the Linux `level()` and `cursorSize()`.
    private static func named(_ value: Any?, _ table: [String: Double], fallback: Double, _ lo: Double, _ hi: Double, _ name: String) throws -> Double {
        if value == nil || bool(value) == true { return fallback }
        if let s = value as? String {
            if let v = table[s.lowercased()] { return v }
            if let v = Double(s.trimmingCharacters(in: .whitespaces)) { return try number(v, lo, hi, name) }
            throw fail("\(name) must be \(table.keys.sorted().joined(separator: ", ")) or a number from \(formatted(lo)) to \(formatted(hi)).")
        }
        return try number(value, lo, hi, name)
    }

    static func color(_ value: Any?) -> NSColor? {
        guard let s = value as? String, s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// Flags (`auto_zoom`, `cursor`, `background`, `background_color`,
    /// `corner_radius`) are shorthand merged into the recipe, exactly like
    /// the Linux CLI: a flag overrides the same setting in `recipe`.
    static func recipe(from args: [String: Any]) throws -> [String: Any] {
        var recipe: [String: Any] = [:]
        if let raw = args["recipe"] {
            if let text = raw as? String {
                guard let data = text.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail("recipe must be a JSON object.") }
                recipe = parsed
            } else if let dict = raw as? [String: Any] { recipe = dict } else { throw fail("recipe must be a JSON object.") }
        }
        if let zoom = args["auto_zoom"] {
            var z = recipe["zoom"] as? [String: Any] ?? [:]
            z["auto"] = true
            if bool(zoom) != true { z["level"] = zoom }
            recipe["zoom"] = z
        }
        if let cursor = args["cursor"] {
            var c = recipe["cursor"] as? [String: Any] ?? [:]
            if bool(cursor) != true { c["size"] = cursor }
            recipe["cursor"] = c
        }
        if args["background"] != nil || args["background_color"] != nil || args["corner_radius"] != nil {
            var bg: [String: Any] = (recipe["background"] as? String).map { ["style": $0] } ?? (recipe["background"] as? [String: Any] ?? [:])
            if let style = args["background"] { bg["style"] = style }
            if let color = args["background_color"] { bg["color"] = color; if args["background"] == nil { bg["style"] = "custom" } }
            if let radius = args["corner_radius"] { bg["corner_radius"] = radius }
            recipe["background"] = bg
        }
        for (flag, key) in [("music", "music"), ("music_volume", "music"), ("title", "title"), ("end", "end")] where args[flag] != nil {
            throw unsupported(key == "music" ? "Music" : "Title and end cards")
        }
        return recipe
    }

    static func plan(_ input: [String: Any]) throws -> Plan {
        let recipe = try object(input, recipeKeys, "The recipe")
        if recipe["music"] != nil { throw unsupported("Music") }
        if recipe["title"] != nil || recipe["end"] != nil { throw unsupported("Title and end cards") }
        var options = PolishOptions()
        options.zoomOnClicks = false; options.backdrop = .none; options.drawCursor = false
        options.showKeystrokes = false
        var plan = Plan(options: options, zoom: false, autoZoom: false, level: levels["normal"]!, moments: [], cursor: false, cursorSize: cursorSizes["normal"]!, background: nil)

        if let raw = recipe["zoom"], bool(raw) != false {
            let z: [String: Any] = try bool(raw) == true ? [:] : object(raw, zoomKeys, "recipe.zoom")
            if z["ramp"] != nil { throw unsupported("recipe.zoom.ramp") }
            if z["gap"] != nil { throw unsupported("recipe.zoom.gap") }
            plan.level = try named(z["level"], levels, fallback: levels["normal"]!, 1.1, 4, "Zoom level")
            if let list = z["moments"] {
                guard let moments = list as? [Any], moments.count <= 40 else { throw fail("recipe.zoom.moments must be a list of at most 40 moments.") }
                plan.moments = try moments.enumerated().map { (i, raw) -> Moment in
                    let m = try object(raw, momentKeys, "recipe.zoom.moments[\(i)]")
                    if m["level"] != nil { throw unsupported("A zoom level per moment") }
                    let start = try number(m["start"], 0, 86400, "moments[\(i)].start"), end = try number(m["end"], 0, 86400, "moments[\(i)].end")
                    guard end > start else { throw fail("moments[\(i)] must end after it starts.") }
                    return Moment(start: start, end: end, x: try number(m["x"], 0, 16000, "moments[\(i)].x"), y: try number(m["y"], 0, 16000, "moments[\(i)].y"))
                }
            }
            plan.autoZoom = bool(z["auto"]) != false && plan.moments.isEmpty
            plan.zoom = plan.autoZoom || !plan.moments.isEmpty
            plan.options.zoomOnClicks = plan.zoom
            plan.options.zoomScale = CGFloat(plan.level)
        }

        if let raw = recipe["cursor"], bool(raw) != false {
            let c: [String: Any] = try bool(raw) == true ? [:] : object(raw, cursorKeys, "recipe.cursor")
            if c["highlight"] != nil { throw unsupported("recipe.cursor.highlight") }
            if c["ripple"] != nil { throw unsupported("recipe.cursor.ripple") }
            plan.cursorSize = try named(c["size"], cursorSizes, fallback: cursorSizes["normal"]!, 1, 3, "Cursor size")
            if let smooth = c["smooth"] {
                if let flag = bool(smooth) { plan.options.smoothCursor = flag } else { plan.options.smoothCursor = try number(smooth, 0, 1, "recipe.cursor.smooth") > 0 }
            }
            plan.cursor = true
            // The Mac's 1x cursor already reads like the system arrow, where
            // Linux's "normal" is 1.5x; keep the names meaning the same size.
            plan.options.cursorSize = CGFloat(plan.cursorSize / 1.5 * 1.6)
        }

        if let raw = recipe["background"], bool(raw) != false, (raw as? String)?.lowercased() != "none" {
            var b: [String: Any] = [:]
            if let s = raw as? String { b["style"] = s } else if bool(raw) != true { b = try object(raw, backgroundKeys, "recipe.background") }
            if b["shadow"] != nil { throw unsupported("recipe.background.shadow") }
            let style = (b["style"] as? String)?.lowercased() ?? (b["color"] != nil ? "custom" : "ocean")
            if style != "none" {
                if style == "custom" {
                    guard let color = color(b["color"]) else { throw fail("A custom background needs recipe.background.color like \"#1E293B\".") }
                    plan.options.backdrop = .custom; plan.options.customColor = color
                } else {
                    guard let backdrop = backdrops[style] else { throw fail("recipe.background.style must be one of dusk, ocean, meadow, slate, custom, none.") }
                    if b["color"] != nil { throw fail("recipe.background.color only goes with style \"custom\" (or leave style out).") }
                    plan.options.backdrop = backdrop
                }
                if let r = b["corner_radius"] { plan.options.cornerRadius = CGFloat(try number(r, 0, 200, "recipe.background.corner_radius")) }
                if let p = b["padding"] { plan.options.paddingFraction = CGFloat(try number(p, 0, 0.3, "recipe.background.padding")) }
                plan.background = style
            }
        }
        guard plan.zoom || plan.cursor || plan.background != nil else {
            throw fail("Nothing to polish. Add --auto-zoom, --cursor, --background, or a --recipe.")
        }
        return plan
    }

    /// Hand-written moments are in source pixels (top-left); the renderer
    /// wants fractions of the frame.
    static func windows(_ moments: [Moment], size: CGSize) -> [ZoomTimeline.Window] {
        moments.map { ZoomTimeline.Window(start: $0.start, end: $0.end, x: min(1, max(0, $0.x / max(1, size.width))), y: min(1, max(0, $0.y / max(1, size.height)))) }
    }
}

extension AgentPolish {
    /// The oriented video size, as the renderer sees it.
    static func videoSize(_ movie: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AgentError("INVALID_VIDEO", "Recording has no playable video track.") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }
}
