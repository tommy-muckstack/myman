import AppKit
import AVFoundation
import GRDB
import ImageIO
import CoreFoundation
import ScreenCaptureKit
import ApplicationServices
import EventKit

/// All mutations run on the main actor through existing stores/controllers.
/// Request IDs are idempotency keys for this app launch; never automatically
/// replay a mutation after a disconnect or process restart.
@MainActor
final class AgentActions {
    let capture: CaptureController
    let meetings: MeetingController
    let voice: VoiceController
    var openSurface: (String) -> Void = { _ in }
    private var jobs: [String: [String: Any]] = [:]
    private var requests: [String: Data] = [:]
    private var order: [String] = []
    private var retired = Set<String>()
    private var resultSizes: [String: Int] = [:]
    private var inFlight = 0
    private var audioCommand = false
    private var deletionObserver: NSObjectProtocol?
    private var contentRevision = 0
    let launchID = UUID().uuidString
    init(capture: CaptureController, meetings: MeetingController, voice: VoiceController) {
        self.capture = capture; self.meetings = meetings; self.voice = voice
        deletionObserver = NotificationCenter.default.addObserver(forName: .captureDeleted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeContentResults() }
        }
    }
    static var catalog: [String: Any] {
        guard let url = Bundle.module.url(forResource: "BrainCompanion", withExtension: nil)?.appendingPathComponent("actions.json"),
              let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func receive(_ request: [String: Any]) -> [String: Any] {
        do {
            guard let method = request["method"] as? String else { throw AgentError("INVALID_REQUEST", "A method is required.") }
            if method == "actions" { return ["ok": true, "launch_id": launchID, "result": Self.catalog] }
            guard let id = request["id"] as? String, UUID(uuidString: id) != nil else { throw AgentError("INVALID_REQUEST", "A UUID request/job id is required.") }
            if method == "job" {
                guard let job = jobs[id] else { throw AgentError("JOB_NOT_FOUND", "Unknown or expired job; do not retry mutations automatically.") }
                return ["ok": true, "launch_id": launchID, "job": job]
            }
            guard method == "invoke", let action = request["action"] as? String,
                  let args = request["arguments"] as? [String: Any],
                  let schema = (Self.catalog["actions"] as? [[String: Any]])?.first(where: { $0["name"] as? String == action })?["inputSchema"] as? [String: Any] else { throw AgentError("UNKNOWN_ACTION", "Use actions to discover commands and arguments.") }
            try AgentSchema.validate(args, schema: schema)
            let fingerprint = try JSONSerialization.data(withJSONObject: ["action": action, "arguments": args], options: [.sortedKeys])
            guard !retired.contains(id) else { throw AgentError("JOB_EXPIRED", "That job has expired. Inspect existing results instead of replaying it.") }
            if let previous = requests[id] {
                guard previous == fingerprint else { throw AgentError("ID_CONFLICT", "This request id was used with different arguments.") }
                return ["ok": true, "launch_id": launchID, "job": jobs[id]!]
            }
            try AgentConsent.validate(action, args: args)
            guard inFlight < 8 else { throw AgentError("BUSY", "Too many active agent jobs; wait for an existing job.") }
            // Retain the most recent 256 terminal results. Never evict running work.
            if order.count >= 256, let index = order.firstIndex(where: { jobs[$0]?["state"] as? String != "running" }) {
                let old = order.remove(at: index); jobs[old] = nil; requests[old] = nil; resultSizes[old] = nil; retired.insert(old)
            }
            requests[id] = fingerprint; order.append(id); inFlight += 1
            jobs[id] = ["id": id, "action": action, "state": "running"]
            let revision = contentRevision
            Task { @MainActor in
                defer { inFlight -= 1; trimResults(keeping: id) }
                do {
                    try AgentConsent.validate(action, args: args)
                    let result = try await execute(action, args)
                    guard revision == contentRevision || ["item.delete", "history.clear"].contains(action) else { throw AgentError("CONTENT_CHANGED", "Captured content was deleted while this job ran. Inspect existing items; do not replay the action automatically.") }
                    jobs[id] = ["id": id, "action": action, "state": "succeeded", "result": result]
                }
                catch { jobs[id] = ["id": id, "action": action, "state": "failed", "error": Self.error(error)] }
            }
            return ["ok": true, "launch_id": launchID, "job": jobs[id]!]
        } catch { return ["ok": false, "launch_id": launchID, "error": Self.error(error)] }
    }
    deinit { if let deletionObserver { NotificationCenter.default.removeObserver(deletionObserver) } }
    private func purgeContentResults() {
        contentRevision += 1
        // A copied image or related-items result can refer indirectly to a
        // deleted capture. Expire all completed results rather than retain it.
        for id in order where jobs[id]?["state"] as? String != "running" {
            jobs[id] = nil; requests[id] = nil; resultSizes[id] = nil; retired.insert(id)
        }
        order.removeAll { retired.contains($0) }
    }
    private func trimResults(keeping id: String) {
        resultSizes[id] = (try? JSONSerialization.data(withJSONObject: jobs[id] ?? [:]).count) ?? 0
        while resultSizes.values.reduce(0, +) > 32 * 1024 * 1024, let index = order.firstIndex(where: { $0 != id && jobs[$0]?["state"] as? String != "running" }) {
            let old = order.remove(at: index); jobs[old] = nil; requests[old] = nil; resultSizes[old] = nil; retired.insert(old)
        }
    }
    static func error(_ error: Error) -> [String: Any] {
        (error as? AgentError)?.json ?? ["code": "ACTION_FAILED", "message": error.localizedDescription]
    }
    private func item(_ args: [String: Any]) throws -> CaptureItem {
        guard let id = args["id"] as? String, let item = CaptureIndex.item(id) else { throw AgentError("NOT_FOUND", "Capture id not found; use collect/search to find its id.") }; return item
    }
    private func shot(_ args: [String: Any]) throws -> (CaptureItem, NSImage) {
        let item = try item(args)
        guard item.kind == "screenshot" else { throw AgentError("INVALID_ARGUMENTS", "Expected a screenshot id.") }
        return (item, try AgentImages.load(URL(fileURLWithPath: item.sourcePath)))
    }
    private func desktopRegion(_ args: [String: Any]) throws -> CGRect {
        let screens = NSScreen.screens
        let selected: NSScreen?
        if let display = args["display"] as? String {
            if display.hasPrefix("id:") { selected = screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == String(display.dropFirst(3)) } }
            else if display == "main" { selected = screens.first }
            else if let index = Int(display), screens.indices.contains(index) { selected = screens[index] }
            else { selected = screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == display } }
        } else { selected = screens.first }
        guard let screen = selected else { throw AgentError("NOT_FOUND", "Display not found; use screens list.") }
        if let values = args["region"] as? [Double] {
            let rect = try AgentImages.rect(values)
            let local = args["coordinates"] as? String == "display-local" || (args["coordinates"] == nil && args["display"] != nil)
            let global = local ? CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height) : rect
            guard (args["display"] != nil ? [screen] : screens).contains(where: { $0.frame.contains(global) }) else { throw AgentError("INVALID_ARGUMENTS", "Region must fit inside the selected display.") }
            return global
        }
        return screen.frame
    }
    private func capturedImage(_ args: [String: Any]) async throws -> (NSImage, CGRect?, Double, String?) {
        if let id = args["window_id"] as? String {
            guard args["display"] == nil, args["region"] == nil, args["coordinates"] == nil else { throw AgentError("INVALID_ARGUMENTS", "Choose window-id or display/region.") }
            let (image, scale) = try await CaptureEngine.shared.captureWindowForAgent(id: id)
            return (image, nil, scale, id)
        }
        let region = try desktopRegion(args)
        let (image, scale) = try await capture.imageForAgent(region: region)
        return (image, region, scale, nil)
    }
    private func wait(_ seconds: Double = 30, until predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < end else { throw AgentError("PROCESSING_TIMEOUT", "The operation is still pending or needs attention in My Man. Inspect app.status before taking another action.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func session(_ args: [String: Any], _ current: String?) throws {
        guard let current, args["session_id"] as? String == current else { throw AgentError("SESSION_MISMATCH", "That recording session is no longer active. Inspect app.status.") }
    }
    private func audioIdle() throws {
        guard meetings.phase == .idle, !meetings.isStarting, !voice.starting, !ScreenRecorder.shared.isBusy else { throw AgentError("BUSY", "Another capture is active.") }
        switch voice.phase { case .idle, .done: break; default: throw AgentError("BUSY", "Dictation is active.") }
    }
    func execute(_ action: String, _ args: [String: Any]) async throws -> Any {
        let isAudio = ["recording.", "dictation."].contains(where: action.hasPrefix) || ["meeting.start", "meeting.stop", "meeting.discard"].contains(action)
        if isAudio { guard !audioCommand else { throw AgentError("BUSY", "An audio control command is in progress.") }; audioCommand = true }
        defer { if isAudio { audioCommand = false } }
        switch action {
        case "app.doctor":
            return ["permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "accessibility": AXIsProcessTrusted(), "calendar": EKEventStore.authorizationStatus(for: .event) == .fullAccess, "input_monitoring": "not_required"], "agents": AgentConsent.status(), "brain_root": Brain.root.path, "brain_available": FileManager.default.fileExists(atPath: Brain.root.appendingPathComponent("catalog.json").path), "screen_recording_supported": ScreenRecorder.isSupported, "pointer_control": "not_supported"] as [String: Any]
        case "windows.list":
            guard CGPreflightScreenCaptureAccess() else { throw AgentError("PERMISSION_REQUIRED", "Grant My Man Screen Recording permission first.") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return content.windows.map { ["id": String($0.windowID), "app": $0.owningApplication?.applicationName ?? "", "title": $0.title ?? "", "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], "coordinates": "quartz-global-top-left"] as [String: Any] }
        case "app.status":
            return ["launch_id": launchID, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    "screen_recording": ["active": ScreenRecorder.shared.isRecording, "busy": ScreenRecorder.shared.isBusy, "session_id": ScreenRecorder.shared.agentSessionID as Any? ?? NSNull()],
                    "meeting": ["session_id": meetings.activeCaptureMeetingID as Any? ?? NSNull(), "phase": String(describing: meetings.phase), "processing": meetings.isTranscribing],
                    "dictation": ["phase": voicePhase, "session_id": voice.agentSessionID as Any? ?? NSNull()],
                    "permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized],
                    "note_processing": MeetingNotesService.shared.stages] as [String: Any]
        case "app.open": openSurface(args["surface"] as! String); return ["opened": true]
        case "screens.list": return NSScreen.screens.map { screen in ["id": String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), "selector": "id:" + String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), "name": screen.localizedName, "frame": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height], "scale": screen.backingScaleFactor] as [String: Any] }
        case "screenshot.capture", "screenshot.capture_markup":
            let date = Date(), meetingID = capture.meetingIDProvider()
            let (image, region, scale, windowID) = try await capturedImage(args)
            let output = action == "screenshot.capture_markup" ? try annotationModel(image: image, path: "", args: args).renderFinal() : image
            var result = try capture.saveAgentImage(output, capturedAt: date, meetingID: meetingID, clipboard: args["clipboard"] as? Bool ?? false)
            result["scale"] = scale
            result["window_id"] = windowID
            if let region {
                result["region"] = [region.minX, region.minY, region.width, region.height]
                result["display"] = NSScreen.screens.first(where: { $0.frame.contains(region) }).flatMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue }
                await capture.saveAgentContext(id: result["id"] as! String, region: region, meetingID: meetingID)
            }
            if args["open_editor"] as? Bool == true { capture.openInEditor(fileURL: URL(fileURLWithPath: result["path"] as! String)) }
            return result
        case "screenshot.edit":
            let (source, image) = try shot(args)
            let model = try annotationModel(image: image, path: source.sourcePath, args: args)
            let count = (args["annotations"] as? [Any])?.count ?? 0
            if args["dry_run"] as? Bool == true { return ["valid": true, "source_id": source.id, "annotation_count": count] as [String: Any] }
            var result = try capture.saveAgentImage(model.renderFinal(), clipboard: args["clipboard"] as? Bool ?? false)
            result["source_id"] = source.id; result["annotation_count"] = count
            if args["open_editor"] as? Bool == true { capture.openInEditor(fileURL: URL(fileURLWithPath: result["path"] as! String)) }
            return result
        case "screenshot.import":
            let path = args["path"] as! String
            guard path.hasPrefix("/") else { throw AgentError("INVALID_ARGUMENTS", "Use an absolute image path.") }
            return try capture.saveAgentImage(AgentImages.load(URL(fileURLWithPath: path)))
        case "screenshot.image":
            let (_, image) = try shot(args); let png = try AgentImages.png(image)
            guard png.count <= 8 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Image exceeds 8 MiB; use the returned local path.") }
            return ["image": ["mimeType": "image/png", "data": png.base64EncodedString()]]
        case "screenshot.remove_background":
            let (source, image) = try shot(args); let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: source.sourcePath))
            model.removeBackground(); try await wait(120) { !model.isRemovingBackground }
            guard model.backgroundRemoved else { throw AgentError("NO_FOREGROUND", "No foreground object could be separated.") }
            return try capture.saveAgentImage(model.renderFinal(), clipboard: args["clipboard"] as? Bool ?? false)
        case "screenshot.ocr":
            let (_, image) = try shot(args); let analysis = await ImageAnalysis.analyze(image)
            return ["text": analysis.text, "regions": analysis.observations.map { ["text": $0.text, "box": [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height]] }] as [String: Any]
        case "clipboard.read":
            if args["format"] as? String == "text" { return ["text": NSPasteboard.general.string(forType: .string) as Any? ?? NSNull(), "change_count": NSPasteboard.general.changeCount] }
            guard let image = NSImage(pasteboard: .general) else { throw AgentError("NOT_FOUND", "Clipboard has no image.") }
            let png = try AgentImages.png(image); guard png.count <= 8 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Clipboard image exceeds 8 MiB.") }
            return ["image": ["mimeType": "image/png", "data": png.base64EncodedString()], "change_count": NSPasteboard.general.changeCount] as [String: Any]
        case "clipboard.write":
            guard (args["text"] != nil) != (args["id"] != nil) else { throw AgentError("INVALID_ARGUMENTS", "Supply text or id, exactly one.") }
            if let text = args["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            else {
                let source = try item(args)
                if args["format"] as? String == "text" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.body, forType: .string) }
                else if source.kind == "screenshot" { let png = try AgentImages.png(AgentImages.load(URL(fileURLWithPath: source.sourcePath))); NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png) }
                else if source.kind == "recording" { let url = URL(fileURLWithPath: source.sourcePath); guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError("NOT_FOUND", "Recording file is missing.") }; NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
                else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.body, forType: .string) }
            }; return ["copied": true, "change_count": NSPasteboard.general.changeCount]
        case "recording.start":
            try audioIdle()
            guard #available(macOS 15.0, *) else { throw AgentError("UNSUPPORTED", "Screen recording requires macOS 15 or later.") }
            let recorder = ScreenRecorder.shared
            try await recorder.startForAgent(region: desktopRegion(args), microphone: args["microphone"] as? Bool ?? false, systemAudio: args["system_audio"] as? Bool ?? true, webcam: args["webcam"] as? Bool ?? false)
            try await wait { recorder.isRecording || !recorder.isBusy }
            guard let id = recorder.agentSessionID, recorder.isRecording else { throw AgentError("CAPTURE_FAILED", "Screen recording did not start.") }
            return ["session_id": id, "state": "recording"]
        case "recording.cancel":
            let recorder = ScreenRecorder.shared; try session(args, recorder.agentSessionID)
            try await recorder.cancelForAgent(); return ["cancelled": true]
        case "recording.stop":
            let recorder = ScreenRecorder.shared; try session(args, recorder.agentSessionID)
            let path = recorder.outputURL?.path; recorder.stop()
            try await wait(180) { !recorder.isBusy }
            guard let record = recorder.lastSavedRecord, record.path == path else { throw AgentError("SAVE_FAILED", "Recording could not be saved.") }
            return ["id": "recording-" + record.id, "path": record.path, "duration": record.duration, "transcript_status": "pending", "brain_path": "recordings/\(Brain.day(record.createdAt))-\(record.id.prefix(8)).md"] as [String: Any]
        case "recording.microphone":
            let recorder = ScreenRecorder.shared; try session(args, recorder.agentSessionID)
            let enabled = args["enabled"] as! Bool
            if recorder.microphoneEnabled != enabled {
                recorder.toggleMicrophone()
                try await wait { recorder.microphoneEnabled == enabled }
            }
            return ["enabled": recorder.microphoneEnabled]
        case "meeting.config.read": return ["auto_record_meetings": SettingsStore.shared.autoRecordMeetings]
        case "meeting.config.update":
            SettingsStore.shared.autoRecordMeetings = args["auto_record_meetings"] as! Bool
            return ["auto_record_meetings": SettingsStore.shared.autoRecordMeetings]
        case "meeting.start":
            try audioIdle(); try await meetings.startForAgent(title: args["title"] as? String)
            return ["session_id": meetings.activeCaptureMeetingID!]
        case "meeting.stop", "meeting.rename", "meeting.discard":
            try session(args, meetings.activeCaptureMeetingID)
            let id = meetings.activeCaptureMeetingID!
            if action == "meeting.rename" { meetings.updateRecordingTitle(args["title"] as! String) }
            else if action == "meeting.discard" { meetings.discardRecording() }
            else { meetings.toggle() }
            return ["id": "meeting-" + id, "state": action == "meeting.stop" ? "processing" : action == "meeting.discard" ? "discarded" : "recording"]
        case "meeting.notes":
            let source = try item(args); guard source.kind == "meeting" else { throw AgentError("INVALID_ARGUMENTS", "Expected a meeting id.") }
            return ["id": source.id, "notes": await MeetingNotesService.shared.notes(meetingID: source.sourceID)]
        case "dictation.start":
            try audioIdle(); voice.toggle(); try await wait(180) { voice.phase == .recording }
            guard let id = voice.agentSessionID else { throw AgentError("CAPTURE_FAILED", "Dictation did not start.") }; return ["session_id": id]
        case "dictation.stop":
            try session(args, voice.agentSessionID); voice.toggle()
            try await wait(300) { if case .done = voice.phase { return true }; return voice.phase == .idle }
            guard case .done(let text) = voice.phase else { throw AgentError("TRANSCRIPTION_FAILED", "No dictation result.") }; return ["text": text, "id": voice.lastDictationID.map { "dictation-" + $0 } as Any? ?? NSNull()]
        case "dictation.cancel": try session(args, voice.agentSessionID); voice.dismiss(); return ["cancelled": true]
        case "note.create":
            var created = Note(body: args["body"] as! String)
            if let title = args["title"] as? String { created.title = title }
            let note = created
            try await Database.shared.write { try note.insert($0) }
            Brain.syncNote(id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
            return ["id": "note-" + note.id, "updated_at": Self.date(note.updatedAt), "brain_path": Brain.noteFilePath(id: note.id, createdAt: note.createdAt)]
        case "note.append":
            let source = try item(args)
            try AgentNoteUpdate.append(source: source, body: args["body"] as! String, expected: args["expected_updated_at"] as? String)
            return try await execute("item.read", ["id": source.id])
        case "note.update":
            let source = try item(args)
            try AgentNoteUpdate.replace(source: source, body: args["body"] as! String, expected: args["expected_updated_at"] as! String)
            return try await execute("item.read", ["id": source.id])
        case "item.read": return Self.json(try item(args))
        case "item.open":
            let source = try item(args)
            if source.kind == "screenshot" { capture.openInEditor(fileURL: URL(fileURLWithPath: source.sourcePath)) }
            else if source.kind == "meeting" { MeetingDocumentController.shared.open(meetingID: source.sourceID) }
            else if source.kind == "note", let note = try await Database.shared.read({ try Note.fetchOne($0, key: source.sourceID) }) { NoteDocumentController.shared.open(note) }
            else if source.kind == "recording" { NSWorkspace.shared.open(URL(fileURLWithPath: source.sourcePath)) }
            else { CaptureActions.open(source) }
            return ["opened": source.id]
        case "item.rename": let source = try item(args); try CaptureLifecycle.rename(source, title: args["title"] as! String); return ["id": source.id]
        case "item.pin": let source = try item(args); if source.pinned != args["pinned"] as! Bool { try CaptureLifecycle.pin(source) }; return ["id": source.id]
        case "item.exclude": let source = try item(args); try CaptureLifecycle.exclude(source, excluded: args["excluded"] as! Bool); return ["id": source.id]
        case "item.delete": let source = try item(args); try CaptureLifecycle.delete(source); return ["deleted": source.id]
        case "item.related": return try RelatedItems.items(for: item(args).id).map { ["item": Self.json($0.item), "score": $0.score, "reason": $0.reason] as [String: Any] }
        case "theme.rename", "theme.pin", "theme.dismiss", "theme.assign", "theme.merge":
            let id = args["id"] as! String
            guard try Database.shared.read({ try Row.fetchOne($0, sql: "SELECT id FROM captureTheme WHERE id = ?", arguments: [id]) }) != nil else { throw AgentError("NOT_FOUND", "Theme not found.") }
            switch action {
            case "theme.rename": try ThemeStore.rename(id, title: args["title"] as! String)
            case "theme.pin": try ThemeStore.pin(id, pinned: args["pinned"] as! Bool)
            case "theme.dismiss": try ThemeStore.dismiss(id)
            case "theme.assign": _ = try item(["id": args["item_id"]!]); try ThemeStore.assign(args["item_id"] as! String, to: id, remove: args["remove"] as? Bool ?? false)
            default:
                let target = args["target_id"] as! String
                guard try Database.shared.read({ try Row.fetchOne($0, sql: "SELECT id FROM captureTheme WHERE id = ? AND dismissed = 0", arguments: [target]) }) != nil else { throw AgentError("NOT_FOUND", "Target theme not found.") }
                try ThemeStore.merge(id, into: target)
            }; return ["id": id]
        case "task.create", "task.update", "task.delete":
            var task: TaskItem
            if action == "task.create" { task = TaskItem(id: UUID().uuidString, title: args["title"] as! String, source: "manual", done: false, createdAt: Date()) }
            else { guard let found = try await Database.shared.read({ try TaskItem.fetchOne($0, key: args["id"] as! String) }) else { throw AgentError("NOT_FOUND", "Task not found.") }; task = found }
            if action == "task.delete" { let taskID = task.id; try await Database.shared.write { _ = try TaskItem.deleteOne($0, key: taskID) } }
            else {
                if let title = args["title"] as? String { task.title = title }
                if let notes = args["notes"] as? String { task.notes = notes }
                if let done = args["done"] as? Bool, done != task.done { task.done = done; task.completedAt = done ? Date() : nil }
                if let due = args["due"] as? String { guard let date = ISO8601DateFormatter().date(from: due) else { throw AgentError("INVALID_ARGUMENTS", "due must be ISO 8601 with timezone.") }; task.dueDate = date }
                if args["clear_due"] as? Bool == true { task.dueDate = nil }
                let updated = task; try await Database.shared.write { try updated.save($0) }
            }; TasksStore.shared.refresh(); return ["id": task.id]
        case "history.clear":
            guard args["confirm"] as? Bool == true else { throw AgentError("CONFIRMATION_REQUIRED", "Set confirm=true only for an explicit request to clear all history.") }
            try CaptureLifecycle.clearHistory(); return ["cleared": true]
        case "settings.read":
            return ["agents": AgentConsent.status(), "agent_actions": UserDefaults.standard.object(forKey: "agentActionsEnabled") as? Bool ?? true, "automatic_themes": UserDefaults.standard.object(forKey: "automaticCaptureThemes") as? Bool ?? true, "semantic_search": UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true, "window_metadata": UserDefaults.standard.bool(forKey: "captureWindowMetadata"), "excluded_apps": UserDefaults.standard.string(forKey: "captureMetadataExcludedApps") ?? ""] as [String: Any]
        case "settings.update":
            for (key, preference) in ["automatic_themes": "automaticCaptureThemes", "semantic_search": "captureSemanticSearch", "window_metadata": "captureWindowMetadata", "excluded_apps": "captureMetadataExcludedApps"] { if let value = args[key] { UserDefaults.standard.set(value, forKey: preference) } }
            if args["window_metadata"] as? Bool == false { try await Database.shared.write { try ScreenshotContext.clearWindowDetails(in: $0) } }
            if let excluded = args["excluded_apps"] as? String { try await Database.shared.write { try ScreenshotContext.clearWindowDetails(excludedApps: excluded, in: $0) } }
            if args["semantic_search"] as? Bool == false { try await Database.shared.write { try $0.execute(sql: "UPDATE captureChunk SET embedding = NULL; UPDATE note SET embedding = NULL; UPDATE screenshot SET embedding = NULL") }; SearchService.clearVectorCache() }
            CaptureEnrichment.shared.schedule(); return try await execute("settings.read", [:])
        case "font.create":
            let (source, image) = try shot(args); image.size = AgentImages.size(image)
            let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: source.sourcePath))
            if let values = args["region"] as? [Double] { let region = try AgentImages.rect(values); guard CGRect(origin: .zero, size: image.size).contains(region), region.width > 10, region.height > 10 else { throw AgentError("INVALID_ARGUMENTS", "Select a text region within the screenshot.") }; model.applyCrop(region) }
            return try await FontWorkbenchController.generateForAgent(image: model.image, title: source.title, sourceID: source.id, name: args["name"] as! String, capturedOnly: args["captured_only"] as? Bool ?? false)
        case "font.file":
            let source = try item(args); guard source.kind == "note", FontProjectStore.exists(source.sourceID), let url = FontProjectStore.asset(source.sourceID, "font.otf") else { throw AgentError("NOT_FOUND", "Saved font not found.") }
            try FontProjectStore.validate(Data(contentsOf: url)); return ["id": source.id, "path": url.path]
        case "font.open":
            let source = try item(args)
            if source.kind == "screenshot" { FontWorkbenchController.open(image: try shot(args).1, sourceURL: URL(fileURLWithPath: source.sourcePath)) }
            else if source.kind == "note" { try FontWorkbenchController.openProject(noteID: source.sourceID) }
            else { throw AgentError("INVALID_ARGUMENTS", "Expected a screenshot or saved font note.") }
            return ["opened": source.id]
        default: throw AgentError("UNKNOWN_ACTION", "Action not implemented.")
        }
    }
    private func annotationModel(image: NSImage, path: String, args: [String: Any]) throws -> EditorModel {
            let size = AgentImages.size(image); image.size = size
            let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: path))
            if let color = args["color"] as? String { model.annotationColor = AgentImages.color(color) }
            for annotation in args["annotations"] as? [[String: Any]] ?? [] {
                let id = UUID(), type = annotation["type"] as! String
                if let color = annotation["color"] as? String { model.annotationColors[id] = AgentImages.color(color) }
                if let font = annotation["font_size"] as? Double { model.annotationFontSizes[id] = font }
                if type == "arrow" {
                    guard let start = annotation["from"] as? [Double], let end = annotation["to"] as? [Double] else { throw AgentError("INVALID_ARGUMENTS", "Arrows require from and to points.") }
                    let from = CGPoint(x: start[0], y: start[1]), to = CGPoint(x: end[0], y: end[1])
                    guard CGRect(origin: .zero, size: size).contains(from), CGRect(origin: .zero, size: size).contains(to) else { throw AgentError("INVALID_ARGUMENTS", "Arrow lies outside the image.") }
                    model.add(.arrow(id: id, from: from, to: to))
                } else {
                    guard let values = annotation["rect"] as? [Double] else { throw AgentError("INVALID_ARGUMENTS", "This annotation requires rect.") }
                    let rect = try AgentImages.rect(values)
                    guard CGRect(origin: .zero, size: size).contains(rect) else { throw AgentError("INVALID_ARGUMENTS", "Annotation lies outside the image.") }
                    switch type {
                    case "image":
                        guard let path = annotation["path"] as? String, path.hasPrefix("/") else { throw AgentError("INVALID_ARGUMENTS", "Overlay requires an absolute image path.") }
                        model.overlayImages[id] = try AgentImages.load(URL(fileURLWithPath: path)); model.add(.image(id: id, rect: rect))
                    case "box": model.add(.box(id: id, rect: rect))
                    case "highlight": model.add(.highlight(id: id, rect: rect))
                    case "pixelate": model.add(.pixelate(id: id, rect: rect))
                    case "text": guard let text = annotation["text"] as? String else { throw AgentError("INVALID_ARGUMENTS", "Text annotation requires text.") }; model.add(.text(id: id, string: text, origin: rect.origin))
                    default: throw AgentError("INVALID_ARGUMENTS", "Unknown annotation.")
                    }
                }
            }
            if let crop = args["crop"] as? [Double] { let rect = try AgentImages.rect(crop); guard CGRect(origin: .zero, size: size).contains(rect), rect.width > 10, rect.height > 10 else { throw AgentError("INVALID_ARGUMENTS", "Crop must fit inside the image and exceed 10 pixels.") }; model.applyCrop(rect) }
            if let background = args["background"] as? String { model.backdrop = BackdropStyle.allCases.first { $0.rawValue.lowercased() == background } ?? .none }
            if let color = args["background_color"] as? String { model.customBackdropColor = AgentImages.color(color); model.backdrop = .custom }
            model.cornerRadius = args["corner_radius"] as? Double ?? 0
            return model
    }
    private var voicePhase: String { switch voice.phase { case .idle: return "idle"; case .recording: return "recording"; case .preparing: return "preparing"; case .transcribing: return "transcribing"; case .done: return "done" } }
    static func date(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func json(_ item: CaptureItem) -> [String: Any] { ["id": item.id, "kind": item.kind, "title": item.title, "body": item.body, "summary": item.summary, "path": item.sourcePath, "captured_at": date(item.capturedAt), "updated_at": date(item.modifiedAt), "pinned": item.pinned, "excluded": item.excluded] }
}

/// Small validator for the deliberately limited JSON Schema subset in actions.json.
/// Both CLI/MCP and the native boundary validate; callers cannot bypass schemas.
enum AgentSchema {
    static func validate(_ value: Any, schema: [String: Any], path: String = "arguments") throws {
        func fail() throws -> Never { throw AgentError("INVALID_ARGUMENTS", "Invalid \(path); inspect the action schema.") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]], Set(object.keys).isSubset(of: Set(properties.keys)), (schema["required"] as? [String] ?? []).allSatisfy({ object[$0] != nil }) else { try fail() }
            for (key, child) in object { try validate(child, schema: properties[key]!, path: path + "." + key) }
        case "array":
            guard let array = value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0), array.count <= (schema["maxItems"] as? Int ?? 100), let child = schema["items"] as? [String: Any] else { try fail() }
            for (i, element) in array.enumerated() { try validate(element, schema: child, path: path + "[\(i)]") }
        case "string":
            guard let string = value as? String, string.count >= (schema["minLength"] as? Int ?? 0), string.count <= (schema["maxLength"] as? Int ?? 1000) else { try fail() }
            if let values = schema["enum"] as? [String], !values.contains(string) { try fail() }
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { try fail() }
        case "boolean": guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { try fail() }
        case "number": guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= (schema["minimum"] as? Double ?? -.greatestFiniteMagnitude), n.doubleValue <= (schema["maximum"] as? Double ?? .greatestFiniteMagnitude) else { try fail() }
        default: try fail()
        }
    }
}

enum AgentImages {
    static func size(_ image: NSImage) -> CGSize {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CGSize(width: cg.width, height: cg.height) }
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let rep = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return image.size
    }
    static func load(_ url: URL) throws -> NSImage {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 32_000_000,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AgentError("INVALID_IMAGE", "Use a supported image up to 32 MiB and 32 megapixels.") }
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
    }
    static func png(_ image: NSImage) throws -> Data {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw AgentError("INVALID_IMAGE", "Cannot encode image.") }; return png
    }
    static func rect(_ values: [Double]) throws -> CGRect {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { throw AgentError("INVALID_ARGUMENTS", "Rectangle requires positive width and height.") }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    static func color(_ hex: String) -> NSColor { let value = UInt32(hex.dropFirst(), radix: 16) ?? 0; return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1) }
}

@MainActor enum AgentNoteUpdate {
    static func append(source: CaptureItem, body: String, expected: String?) throws {
        guard source.kind == "note" else { throw AgentError("INVALID_ARGUMENTS", "Expected a note.") }
        let note = try Database.shared.write { db -> Note in
            guard var note = try Note.fetchOne(db, key: source.sourceID) else { throw AgentError("NOT_FOUND", "Note not found.") }
            if let expected, AgentActions.date(note.updatedAt) != expected { throw AgentError("EDIT_CONFLICT", "Note changed; read it again before appending.") }
            note.body += (note.body.isEmpty ? "" : "\n\n") + body
            guard note.body.count <= 500000 else { throw AgentError("TOO_LARGE", "The resulting note exceeds 500,000 characters.") }
            note.updatedAt = Date(); try note.update(db); return note
        }
        Brain.syncNote(id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
    static func replace(source: CaptureItem, body: String, expected: String) throws {
        guard source.kind == "note" else { throw AgentError("INVALID_ARGUMENTS", "Expected a note.") }
        let note = try Database.shared.write { db -> Note in
            guard var note = try Note.fetchOne(db, key: source.sourceID) else { throw AgentError("NOT_FOUND", "Note not found.") }
            guard AgentActions.date(note.updatedAt) == expected else { throw AgentError("EDIT_CONFLICT", "Note changed; read it again before updating.") }
            note.body = body; note.title = Note.deriveTitle(from: body); note.updatedAt = Date()
            try note.update(db); return note
        }
        Brain.syncNote(id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
