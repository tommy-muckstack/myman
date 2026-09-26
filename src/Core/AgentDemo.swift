import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `myman demo` on the Mac: one command from a steps file to a finished demo.
/// It opens the app, hides every other app so only that app is on screen,
/// records the app's window while it performs the steps with the mouse and
/// keyboard, brings the other apps back, then polishes the recording. The
/// steps file and its names are the same as the Linux companion's.
enum DemoScript {
    static let scriptKeys = ["app", "window", "region", "steps", "title", "end", "polish", "close", "focus", "max_duration"]
    static let stepKinds = ["wait", "move", "click", "type", "key", "scroll"]
    static let stepKeys: [String: [String]] = ["wait": [], "move": ["seconds"], "click": ["seconds", "button", "double"], "type": ["cps", "at"], "key": [], "scroll": []]
    static let defaultPolish: [String: Any] = ["zoom": ["auto": true], "cursor": ["size": "big"], "background": "dusk", "music": "upbeat"]
    static let leadIn = 0.8, leadOut = 1.2

    enum Step: Equatable {
        case wait(Double)
        case move(CGPoint, seconds: Double)
        case click(CGPoint, seconds: Double, button: Int, double: Bool)
        case type(String, cps: Double, at: CGPoint?)
        case key(String)
        case scroll(Int)
    }

    struct Plan {
        var app: String?
        var window: String?
        /// "window", "display", or a rectangle in points from the top-left of the main display.
        var region: String
        var rect: CGRect?
        var steps: [Step]
        /// The recipe for record polish (zoom "steps" means zoom where the demo acted), or nil for none.
        var polish: [String: Any]?
        var close: Bool
        var focus: Bool
        var estimatedSeconds: Double
        var maxDuration: Double

        var json: [String: Any] {
            var out: [String: Any] = ["app": app.map { $0 as Any } ?? NSNull(), "window": window.map { $0 as Any } ?? NSNull(),
                                      "region": rect.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] as Any } ?? region,
                                      "steps": steps.count, "polish": polish.map { $0 as Any } ?? false, "close": close, "focus": focus,
                                      "estimated_seconds": estimatedSeconds, "max_duration": maxDuration]
            out["hides_other_apps"] = focus
            return out
        }
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    private static func fail(_ message: String) -> AgentError { AgentError("INVALID_ARGUMENTS", message) }
    private static func number(_ value: Any?, _ lo: Double, _ hi: Double, _ name: String) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, (lo...hi).contains(n.doubleValue) else {
            throw fail("\(name) must be a number from \(fmt(lo)) to \(fmt(hi)).")
        }
        return n.doubleValue
    }
    private static func point(_ value: Any?, _ name: String) throws -> CGPoint {
        guard let pair = value as? [Any], pair.count == 2 else { throw fail("\(name) must be [x, y] inside the recorded area.") }
        return CGPoint(x: try number(pair[0], 0, 16000, "\(name)[0]"), y: try number(pair[1], 0, 16000, "\(name)[1]"))
    }
    private static func flag(_ value: Any?, _ name: String) throws -> Bool? {
        guard let value else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw fail("\(name) must be true or false.") }
        return n.boolValue
    }
    static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_]+(\\+[A-Za-z0-9_]+)*$")

    /// Validate a steps file and fill defaults. Unknown keys are errors, never ignored.
    static func parse(_ raw: Any?, app appFlag: String? = nil) throws -> Plan {
        guard let script = raw as? [String: Any] else { throw fail("The demo script must be a JSON object with \"steps\".") }
        if let extra = script.keys.sorted().first(where: { !scriptKeys.contains($0) }) {
            throw fail("The demo script has unknown key \(extra). Allowed: \(scriptKeys.joined(separator: ", ")).")
        }
        guard let list = script["steps"] as? [Any], (1...200).contains(list.count) else { throw fail("\"steps\" must be a list of 1 to 200 steps.") }
        let steps: [Step] = try list.enumerated().map { i, item in
            let at = "steps[\(i)]"
            guard let s = item as? [String: Any] else { throw fail("\(at) must be an object such as {\"click\": [120, 80]}.") }
            let kinds = s.keys.filter { stepKinds.contains($0) }
            guard kinds.count == 1, let kind = kinds.first else { throw fail("\(at) needs exactly one of \(stepKinds.joined(separator: ", ")).") }
            if let other = s.keys.sorted().first(where: { $0 != kind && !(stepKeys[kind] ?? []).contains($0) }) {
                throw fail("\(at) has unknown key \(other). A \(kind) step allows: \(([kind] + (stepKeys[kind] ?? [])).joined(separator: ", ")).")
            }
            let v = s[kind]
            switch kind {
            case "wait": return .wait(try number(v, 0, 30, "\(at).wait"))
            case "move": return .move(try point(v, "\(at).move"), seconds: try s["seconds"].map { try number($0, 0, 5, "\(at).seconds") } ?? 0.6)
            case "click":
                return .click(try point(v, "\(at).click"), seconds: try s["seconds"].map { try number($0, 0, 5, "\(at).seconds") } ?? 0.6,
                              button: Int(try s["button"].map { try number($0, 1, 3, "\(at).button") } ?? 1), double: try flag(s["double"], "\(at).double") ?? false)
            case "type":
                guard let text = v as? String, (1...2000).contains(text.count) else { throw fail("\(at).type must be text of 1 to 2000 characters.") }
                return .type(text, cps: try s["cps"].map { try number($0, 2, 60, "\(at).cps") } ?? 14, at: try s["at"].map { try point($0, "\(at).at") })
            case "key":
                guard let key = v as? String, keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil, (try? DemoInput.chord(key)) != nil else {
                    throw fail("\(at).key must be a key or combination such as \"Return\" or \"cmd+s\".")
                }
                return .key(key)
            default:
                let n = Int(try number(v, -50, 50, "\(at).scroll"))
                guard n != 0 else { throw fail("\(at).scroll must not be 0.") }
                return .scroll(n)
            }
        }
        func name(_ value: Any?, _ label: String) throws -> String? {
            guard let value else { return nil }
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...200).contains(s.count) else {
                throw fail("\(label) must be an app name such as \"Spotify\", a bundle ID, or a path to a .app.")
            }
            return s
        }
        let app = try name(appFlag, "--app") ?? name(script["app"], "\"app\"")
        let window = try script["window"].map { value -> String in
            guard let s = value as? String, (1...200).contains(s.count) else { throw fail("\"window\" must be part of the app window's title.") }
            return s
        }
        var region = app != nil || window != nil ? "window" : "display", rect: CGRect?
        if let r = script["region"] {
            if let values = r as? [Any] {
                guard values.count == 4 else { throw fail("\"region\" must be \"window\", \"display\" or [x, y, width, height].") }
                let n = try values.enumerated().map { k, v in try number(v, k < 2 ? 0 : 16, 16000, "region[\(k)]") }
                rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]); region = "area"
            } else if let s = r as? String, ["window", "display"].contains(s) { region = s }
            else { throw fail("\"region\" must be \"window\", \"display\" or [x, y, width, height].") }
        }
        if region == "window" && app == nil && window == nil { throw fail("\"region\": \"window\" needs \"app\" or \"window\".") }
        var polish: [String: Any]?
        let polishOff = (script["polish"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false
        if !polishOff {
            if let p = script["polish"], !(p is [String: Any]) { throw fail("\"polish\" must be a recipe object like record polish takes, or false.") }
            let given = script["polish"] as? [String: Any] ?? [:]
            var merged = defaultPolish.merging(given) { _, new in new }
            if given["zoom"] == nil { merged["zoom"] = "steps" }
            for key in ["title", "end"] { if let v = script[key] { merged[key] = v } }
            polish = merged
        }
        let seconds = steps.reduce(leadIn + leadOut) { t, s in
            switch s {
            case .wait(let w): return t + w
            case .move(_, let d): return t + d
            case .click(_, let d, _, let double): return t + d + (double ? 0.25 : 0.15)
            case .type(let text, let cps, _): return t + Double(text.count) / cps
            case .key, .scroll: return t + 0.2
            }
        }
        let max = try script["max_duration"].map { try number($0, 5, 600, "\"max_duration\"") } ?? min(600, (seconds * 1.5 + 10).rounded(.up))
        guard seconds <= max else { throw fail("The steps take about \(Int(seconds.rounded())) s, longer than max_duration \(fmt(max)).") }
        return Plan(app: app, window: window, region: region, rect: rect, steps: steps, polish: polish,
                    close: try flag(script["close"], "\"close\"") ?? true, focus: try flag(script["focus"], "\"focus\"") ?? true,
                    estimatedSeconds: (seconds * 10).rounded() / 10, maxDuration: max)
    }

    /// The demo knows what it did, so it zooms where it acted: on each click,
    /// and on each typing burst (at "at", or where it last clicked). Times are
    /// seconds into the recording; points are in the recorded area.
    struct Acted { var click: (t: Double, p: CGPoint)?; var typing: (from: Double, to: Double, p: CGPoint?)? }
    static func moments(_ acted: [Acted], scale: Double) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for a in acted {
            if let c = a.click { out.append(["start": max(0, c.t - 0.5), "end": c.t + 1, "x": Double(c.p.x) * scale, "y": Double(c.p.y) * scale]) }
            if let g = a.typing, let p = g.p { out.append(["start": max(0, g.from - 0.3), "end": g.to + 0.8, "x": Double(p.x) * scale, "y": Double(p.y) * scale]) }
        }
        return Array(out.sorted { ($0["start"] as! Double) < ($1["start"] as! Double) }.prefix(40))
    }
}

/// Mouse and keyboard input for demo steps, posted as system events. Points
/// are global, in points from the top-left of the main display.
enum DemoInput {
    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53, "delete": 117,
        "home": 115, "end": 119, "page_up": 116, "prior": 116, "page_down": 121, "next": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28,
        "0": 29, "bracketright": 30, "o": 31, "u": 32, "bracketleft": 33, "i": 34, "p": 35, "l": 37, "j": 38, "apostrophe": 39,
        "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "grave": 50,
    ]
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl, "alt": .maskAlternate, "option": .maskAlternate, "shift": .maskShift,
    ]
    /// "cmd+shift+s" becomes the S key with Command and Shift held.
    static func chord(_ text: String) throws -> (CGKeyCode, CGEventFlags) {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, let code = keyCodes[last] else { throw AgentError("INVALID_ARGUMENTS", "Unknown key \(text).") }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifiers[part] else { throw AgentError("INVALID_ARGUMENTS", "Unknown modifier \(part) in \(text).") }
            flags.insert(flag)
        }
        return (code, flags)
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    private static func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
    private static func pause(_ seconds: Double) async throws { if seconds > 0 { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) } }

    /// Ease the pointer along a curve so the drawn cursor glides like a person's.
    static func glide(to target: CGPoint, seconds: Double) async throws {
        let from = location, n = max(1, Int((seconds * 60).rounded()))
        for i in 1...n {
            let k = Double(i) / Double(n), e = k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e), mouseButton: .left))
            if n > 1 { try await pause(seconds / Double(n)) }
        }
    }
    static func click(at point: CGPoint, button: Int, double: Bool) async throws {
        let (down, up, which): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case 3: (.rightMouseDown, .rightMouseUp, .right)
        case 2: (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        for count in 1...(double ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: which)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                post(event)
            }
            if double && count == 1 { try await pause(0.12) }
        }
    }
    static func type(_ text: String, cps: Double) async throws {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
            try await pause(1 / cps)
        }
    }
    static func key(_ text: String) throws {
        let (code, flags) = try chord(text)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            post(event)
        }
    }
    /// Positive scrolls down, as on Linux.
    static func scroll(_ lines: Int) async throws {
        for _ in 0..<abs(lines) {
            post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines > 0 ? -1 : 1, wheel2: 0, wheel3: 0))
            try await pause(0.06)
        }
    }
}

/// The apps around a demo: finding and opening the one being shown, and
/// hiding every other app while it records.
@MainActor enum DemoStage {
    static func appURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if name.hasPrefix("/") { return name.hasSuffix(".app") && fm.fileExists(atPath: name) ? URL(fileURLWithPath: name) : nil }
        if !name.contains(" "), name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let wanted = (name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name).lowercased()
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            if let hit = entries.first(where: { $0.lowercased() == wanted + ".app" }) { return URL(fileURLWithPath: folder).appendingPathComponent(hit) }
        }
        return nil
    }
    static func running(_ name: String) -> NSRunningApplication? {
        let lower = name.lowercased()
        if lower == "myman" || lower == "my man" { return .current }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased() == lower || $0.bundleIdentifier?.lowercased() == lower || $0.bundleURL?.path == name)
        }
    }
    /// Returns the app and whether this demo launched it.
    static func open(_ name: String) async throws -> (NSRunningApplication, Bool) {
        if let app = running(name) { activate(app); return (app, false) }
        guard let url = appURL(name) else {
            throw AgentError("NOT_FOUND", "No app named \(name) was found in Applications. Pass its name as shown in the Dock, its bundle ID, or a path to the .app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return (app, true)
    }
    static func activate(_ app: NSRunningApplication) {
        if app == .current { NSApp.activate() } else { app.activate() }
    }
    /// Hide every other visible app (this app's own windows stay, as they are
    /// not in the recorded area). Returns what was hidden so it can be restored.
    static func hideOthers(except app: NSRunningApplication) -> [NSRunningApplication] {
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != app.processIdentifier && $0 != .current
        }
        return others.filter { $0.hide() }
    }
    static func restore(_ hidden: [NSRunningApplication], front: NSRunningApplication?) {
        for app in hidden where !app.isTerminated { app.unhide() }
        if let front, !front.isTerminated, front != .current { front.activate() }
    }
    /// The app's largest on-screen window, in points from the top-left of the
    /// main display. Waits up to 15 seconds for it to appear.
    static func window(of app: NSRunningApplication, title: String?) async throws -> CGRect {
        for _ in 0..<60 {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let rects = list.compactMap { info -> CGRect? in
                guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier, (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                      rect.width >= 64, rect.height >= 64 else { return nil }
                if let title, !((info[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains(title) { return nil }
                return rect
            }
            if let best = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) { return best }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AgentError("NOT_FOUND", title.map { "No window with \"\($0)\" in its title appeared within 15 seconds." }
                         ?? "\(app.localizedName ?? "The app") showed no window within 15 seconds. Open one, or pass \"window\" with part of its title.")
    }
    /// A top-left rectangle in points becomes the bottom-left global rectangle record start takes.
    static func global(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
    /// Keep the recorded area on the display it is mostly on.
    static func clamp(_ rect: CGRect) -> CGRect {
        let g = global(rect)
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(g).width * $0.frame.intersection(g).height < $1.frame.intersection(g).width * $1.frame.intersection(g).height }) else { return rect }
        let fit = g.intersection(screen.frame).integral
        let height = NSScreen.screens.first?.frame.height ?? fit.maxY
        return CGRect(x: fit.minX, y: height - fit.maxY, width: fit.width, height: fit.height)
    }
}

extension AgentActions {
    func runDemo(_ args: [String: Any]) async throws -> [String: Any] {
        let plan = try DemoScript.parse(args["script"], app: args["app"] as? String)
        // Check the polish recipe before anything opens or records.
        var recipe = plan.polish
        var warnings: [String] = []
        if var r = recipe {
            let chosen = ((args["script"] as? [String: Any])?["polish"] as? [String: Any])?["music"] != nil
            if !chosen, args["music_track"] == nil {
                // The built-in tracks are composed by the myman command; a raw call keeps the demo and skips the music.
                r.removeValue(forKey: "music"); warnings.append("No music: built-in tracks are added when you run myman demo (the command or MCP server).")
            }
            var check = r; if check["zoom"] as? String == "steps" { check["zoom"] = ["auto": true] }
            _ = try AgentPolish.plan(check)
            recipe = r
        }
        if args["dry_run"] as? Bool == true {
            return plan.json.merging(["dry_run": true, "warnings": warnings, "accessibility_trusted": AXIsProcessTrusted(),
                                      "note": "Coordinates are points from the top-left of the recorded area (the app window by default)."]) { a, _ in a }
        }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw AgentError("PERMISSION_REQUIRED", "Allow My Man under System Settings → Privacy & Security → Accessibility so the demo can move the mouse and type, then run it again.")
        }
        let front = NSWorkspace.shared.frontmostApplication
        var target: NSRunningApplication?, launched = false, hidden: [NSRunningApplication] = [], session: String?
        defer {
            if plan.focus { DemoStage.restore(hidden, front: front) }
            if plan.close, launched, let target, target != .current, !target.isTerminated { target.terminate() }
        }
        do {
            if let name = plan.app { let opened = try await DemoStage.open(name); target = opened.0; launched = opened.1 }
            else if plan.window != nil { target = NSWorkspace.shared.frontmostApplication }
            if plan.focus { hidden = DemoStage.hideOthers(except: target ?? .current) }
            if let target { DemoStage.activate(target) }
            var area: CGRect
            switch plan.region {
            case "window":
                guard let target else { throw AgentError("NOT_FOUND", "No app to record.") }
                area = try await DemoStage.window(of: target, title: plan.window)
                DemoStage.activate(target)
                try await Task.sleep(for: .milliseconds(400))
            case "area": area = plan.rect!
            default:
                let screen = NSScreen.screens.first?.frame ?? .zero
                area = CGRect(origin: .zero, size: screen.size)
            }
            area = DemoStage.clamp(area)
            guard area.width >= 16, area.height >= 16 else { throw AgentError("INVALID_ARGUMENTS", "The recorded area is off screen.") }
            let origin = area.origin
            func global(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
            try await DemoInput.glide(to: CGPoint(x: area.midX, y: area.midY), seconds: 0)
            let g = DemoStage.global(area)
            let started = try await execute("recording.start", ["region": [Double(g.minX), Double(g.minY), Double(g.width), Double(g.height)], "hide_cursor": true,
                                                                "max_duration": plan.maxDuration, "system_audio": false, "microphone": false]) as? [String: Any]
            session = started?["session_id"] as? String
            let clock = Date()
            func now() -> Double { Date().timeIntervalSince(clock) }
            var acted: [DemoScript.Acted] = [], last: CGPoint?, clicks = 0
            try await Task.sleep(for: .milliseconds(Int(DemoScript.leadIn * 1000)))
            for step in plan.steps {
                switch step {
                case .wait(let s): try await Task.sleep(for: .milliseconds(Int(s * 1000)))
                case .move(let p, let s): try await DemoInput.glide(to: global(p), seconds: s)
                case .click(let p, let s, let button, let double):
                    try await DemoInput.glide(to: global(p), seconds: s)
                    acted.append(.init(click: (now(), p))); last = p; clicks += 1
                    try await DemoInput.click(at: global(p), button: button, double: double)
                    try await Task.sleep(for: .milliseconds(150))
                case .type(let text, let cps, let at):
                    let from = now()
                    try await DemoInput.type(text, cps: cps)
                    acted.append(.init(typing: (from, now(), at ?? last)))
                case .key(let k): try DemoInput.key(k); try await Task.sleep(for: .milliseconds(200))
                case .scroll(let n): try await DemoInput.scroll(n); try await Task.sleep(for: .milliseconds(200))
                }
            }
            try await Task.sleep(for: .milliseconds(Int(DemoScript.leadOut * 1000)))
            guard let id = session else { throw AgentError("CAPTURE_FAILED", "Screen recording did not start.") }
            let recorded = try await execute("recording.stop", ["session_id": id]) as? [String: Any] ?? [:]
            session = nil
            if plan.focus { DemoStage.restore(hidden, front: front); hidden = [] }
            let recordingID = (recorded["id"] as? String) ?? (recorded["item_id"] as? String) ?? ""
            var result: [String: Any] = ["recording_id": recordingID, "steps_run": plan.steps.count, "clicks": clicks,
                                         "region": [Double(area.minX), Double(area.minY), Double(area.width), Double(area.height)], "app": target?.localizedName.map { $0 as Any } ?? NSNull(),
                                         "hid_other_apps": plan.focus, "warnings": warnings]
            guard var polish = recipe, !recordingID.isEmpty else {
                return result.merging(["id": recordingID, "note": "Polish it with myman record polish --id \(recordingID) --json."]) { a, _ in a }
            }
            if polish["zoom"] as? String == "steps" {
                var scale = 1.0
                if let path = recorded["path"] as? String ?? recorded["video_path"] as? String, let size = try? await AgentPolish.videoSize(URL(fileURLWithPath: path)), area.width > 0 {
                    scale = Double(size.width) / Double(area.width)
                }
                let moments = DemoScript.moments(acted, scale: scale)
                if moments.isEmpty { polish.removeValue(forKey: "zoom") } else { polish["zoom"] = ["moments": moments] }
            }
            var polishArgs: [String: Any] = ["id": recordingID, "recipe": polish]
            if let track = args["music_track"] { polishArgs["music_track"] = track }
            let polished = try await execute("recording.polish", polishArgs) as? [String: Any] ?? [:]
            result.merge(polished) { _, new in new }
            result["recording_id"] = recordingID
            result["warnings"] = warnings + (polished["warnings"] as? [String] ?? [])
            result["note"] = "Raw recording kept as \(recordingID)."
            return result
        } catch {
            if let session { _ = try? await execute("recording.cancel", ["session_id": session]) }
            throw error
        }
    }
}
