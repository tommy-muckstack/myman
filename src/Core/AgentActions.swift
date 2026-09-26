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
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var inFlight = 0
    private var audioCommand = false
    private var deletionObserver: NSObjectProtocol?
    private var exclusionObserver: NSObjectProtocol?
    private var contentRevision = 0
    let launchID = UUID().uuidString
    private let journal = AgentJournal.shared
    init(capture: CaptureController, meetings: MeetingController, voice: VoiceController) {
        self.capture = capture; self.meetings = meetings; self.voice = voice
        WorkflowActivity.cancel = { [weak self] id, human in
            guard let self, let job = self.jobs[id], job["state"] as? String == "running", let action = job["action"] as? String, WorkflowActivity.cancellable.contains(action), let task = self.activeTasks[id] else { throw AgentError("NOT_CANCELLABLE", "This command cannot be stopped safely. Inspect its result before continuing.") }
            guard human || job["owner"] as? String == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "This request belongs to another agent.") }
            self.jobs[id]?["stop_requested"] = true
            task.cancel()
        }
        deletionObserver = NotificationCenter.default.addObserver(forName: .captureDeleted, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.purgeContentResults(); AgentCollaboration.shared.purge(itemID: notification.object as? String); AgentBriefs.shared.purge(itemID: notification.object as? String); DictationHistory.shared.purge(itemID: notification.object as? String); MeetingDecisions.shared.purge(itemID: notification.object as? String); FloatingReference.purge(itemID: notification.object as? String); SharePublishing.shared.purge(sourceID: notification.object as? String) }
        }
        exclusionObserver = NotificationCenter.default.addObserver(forName: .captureExcluded, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.purgeContentResults(); AgentCollaboration.shared.purge(itemID: notification.object as? String); AgentBriefs.shared.purge(itemID: notification.object as? String); DictationHistory.shared.purge(itemID: notification.object as? String); MeetingDecisions.shared.purge(itemID: notification.object as? String); FloatingReference.purge(itemID: notification.object as? String); SharePublishing.shared.purge(sourceID: notification.object as? String) }
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
            try AgentIdentity.shared.checkMachine(request)
            if method == "actions" {
                let discoveredAgent = request["credential"] != nil ? try AgentIdentity.shared.authenticate(request) : nil
                var catalog = Self.catalog
                catalog["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                catalog["app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
                catalog["permissions"] = AgentConsent.status()
                catalog["machine"] = AgentIdentity.shared.machine
                catalog["named_agents_required"] = AgentIdentity.shared.required
                if let agent = discoveredAgent {
                    catalog["agent"] = ["id": agent.id, "name": agent.name, "scopes": agent.scopes.sorted()]
                    catalog["effective_grants"] = AgentConsent.status().mapValues { $0 }.filter { $0.key == "enabled" || agent.scopes.contains($0.key) }
                }
                catalog["recovery"] = ["durable": true, "retention_days": 7, "automatic_replay": false]
                return ["ok": true, "launch_id": launchID, "result": catalog]
            }
            let principal = try AgentIdentity.shared.authenticate(request)
            if method == "jobs" {
                guard AgentConsent.status()["enabled"] == true else { throw AgentError("AGENT_DISABLED", "Local app actions are disabled.") }
                return ["ok": true, "launch_id": launchID, "jobs": journal.list().filter { ($0["owner"] as? String ?? "local") == principal.id }, "retention_days": 7]
            }
            guard let id = request["id"] as? String, UUID(uuidString: id) != nil else { throw AgentError("INVALID_REQUEST", "A UUID request/job id is required.") }
            if method == "job" {
                guard let job = jobs[id] ?? journal.job(id) else { throw AgentError("JOB_NOT_FOUND", "Unknown or expired job; do not retry mutations automatically.") }
                guard (job["owner"] as? String ?? "local") == principal.id else { throw AgentError("NOT_OWNER", "This job belongs to another agent.") }
                try AgentIdentity.shared.validate(principal, action: job["action"] as? String ?? "item.read")
                try AgentConsent.validate(job["action"] as? String ?? "item.read", args: ["confirm": true])
                return ["ok": true, "launch_id": launchID, "job": job, "recovered": jobs[id] == nil]
            }
            guard method == "invoke", let action = request["action"] as? String,
                  let args = request["arguments"] as? [String: Any],
                  let schema = (Self.catalog["actions"] as? [[String: Any]])?.first(where: { $0["name"] as? String == action })?["inputSchema"] as? [String: Any] else { throw AgentError("UNKNOWN_ACTION", "Use actions to discover commands and arguments.") }
            try AgentSchema.validate(args, schema: schema)
            try AgentIdentity.shared.validate(principal, action: action)
            let fingerprint = try JSONSerialization.data(withJSONObject: principal.id == "local" ? ["action": action, "arguments": args] : ["action": action, "arguments": args, "owner": principal.id], options: [.sortedKeys])
            guard !retired.contains(id) else { throw AgentError("JOB_EXPIRED", "That job has expired. Inspect existing results instead of replaying it.") }
            if let previous = requests[id] {
                guard previous == fingerprint else { throw AgentError("ID_CONFLICT", "This request id was used with different arguments.") }
                try AgentConsent.validate(action, args: args)
                return ["ok": true, "launch_id": launchID, "job": jobs[id]!]
            }
            try AgentConsent.validate(action, args: args)
            if let prior = try journal.prior(id, fingerprint: fingerprint) { return ["ok": true, "launch_id": launchID, "job": prior, "recovered": true] }
            guard inFlight < 8 else { throw AgentError("BUSY", "Too many active agent jobs; wait for an existing job.") }
            // Retain the most recent 256 terminal results. Never evict running work.
            if order.count >= 256, let index = order.firstIndex(where: { jobs[$0]?["state"] as? String != "running" }) {
                let old = order.remove(at: index); jobs[old] = nil; requests[old] = nil; resultSizes[old] = nil; retired.insert(old)
            }
            try journal.begin(id, action: action, fingerprint: fingerprint, owner: principal.id, inputs: WorkflowActivity.references(args))
            requests[id] = fingerprint; order.append(id); inFlight += 1
            jobs[id] = ["id": id, "action": action, "state": "running", "owner": principal.id]
            let revision = contentRevision
            activeTasks[id] = Task { @MainActor in
                defer {
                    activeTasks[id] = nil
                    inFlight -= 1; trimResults(keeping: id)
                    if let job = jobs[id], !journal.finish(id, job: job) { jobs[id]?["recovery_persisted"] = false }
                }
                do {
                    try AgentConsent.validate(action, args: args)
                    try Task.checkCancellation()
                    let result = try await AgentContext.$principal.withValue(principal) {
                        try await AgentContext.$jobID.withValue(id) { try await executeCoordinated(action, args) }
                    }
                    try Task.checkCancellation()
                    guard revision == contentRevision || ["item.delete", "item.exclude", "history.clear"].contains(action) else { AgentMediaStore.shared.purge(); throw AgentError("CONTENT_CHANGED", "Captured content was deleted while this job ran. Inspect existing items; do not replay the action automatically.") }
                    jobs[id] = ["id": id, "action": action, "state": "succeeded", "result": result, "owner": principal.id]
                }
                catch is CancellationError { jobs[id] = ["id": id, "action": action, "state": "cancelled", "error": ["code": "CANCELLED", "message": "Stopped. Temporary output may already exist; inspect saved files before continuing."], "owner": principal.id] }
                catch { jobs[id] = ["id": id, "action": action, "state": "failed", "error": Self.error(error), "owner": principal.id] }
            }
            return ["ok": true, "launch_id": launchID, "job": jobs[id]!]
        } catch { return ["ok": false, "launch_id": launchID, "error": Self.error(error)] }
    }
    deinit { if let exclusionObserver { NotificationCenter.default.removeObserver(exclusionObserver) }; if let deletionObserver { NotificationCenter.default.removeObserver(deletionObserver) } }
    private func purgeContentResults() {
        contentRevision += 1
        journal.purgeContent()
        ScreenRecorder.shared.clearCompletedAgentSessions()
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
    private func awaitReady(_ args: [String: Any]) async throws -> [String: Any] {
        guard ["id", "job_id", "session_id"].filter({ args[$0] != nil }).count == 1 else { throw AgentError("INVALID_ARGUMENTS", "Select exactly one item id, job_id, or session_id.") }
        guard args["id"] != nil || args["stage"] == nil else { throw AgentError("INVALID_ARGUMENTS", "stage applies only to item IDs.") }
        let deadline = Date().addingTimeInterval(args["timeout"] as? Double ?? 120)
        while true {
            try Task.checkCancellation()
            try AgentIdentity.shared.validate(AgentContext.principal, action: "app.wait")
            try AgentConsent.validate("app.wait", args: args)
            let status: [String: Any]
            if let id = args["job_id"] as? String {
                guard let job = jobs[id] ?? journal.job(id) else { throw AgentError("JOB_NOT_FOUND", "Unknown or expired job; do not repeat its action.") }
                guard (job["owner"] as? String ?? "local") == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "This job belongs to another agent.") }
                guard job["action"] as? String != "app.wait" else { throw AgentError("INVALID_ARGUMENTS", "Wait on the original operation, not another waiter.") }
                try AgentIdentity.shared.validate(AgentContext.principal, action: job["action"] as? String ?? "item.read")
                try AgentConsent.validate(job["action"] as? String ?? "item.read", args: ["confirm": true])
                let state = job["state"] as? String ?? "unknown"
                if ["failed", "interrupted"].contains(state) { throw AgentError("WAIT_FAILED", "The original job did not complete.", details: ["job": job]) }
                status = ["job_id": id, "state": state, "ready": state == "succeeded", "job": job]
            } else if let id = args["session_id"] as? String {
                var value = try await recordingStatus(id)
                let state = value["state"] as? String ?? "unknown"
                if ["failed", "cancelled", "interrupted"].contains(state) { throw AgentError("WAIT_FAILED", "Recording did not finalize.", details: ["session": value]) }
                value["ready"] = state == "finalized"; status = value
            } else {
                try AgentConsent.validate("item.read", args: args)
                let id = args["id"] as! String, stage = args["stage"] as? String ?? "indexed"
                status = try await Task.detached(priority: .utility) { try AgentReadiness.item(id, stage: stage) }.value
            }
            if status["ready"] as? Bool == true { return status }
            guard Date() < deadline else { throw AgentError("PROCESSING_TIMEOUT", "The requested result is not ready. No work was started or retried.", details: ["readiness": status]) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    private func executeCoordinated(_ action: String, _ args: [String: Any]) async throws -> Any {
        try AgentIdentity.shared.validate(AgentContext.principal, action: action)
        if action.hasPrefix("brief.") { return try await AgentBriefs.shared.execute(action, args) }
        if ["agent.", "bundle.", "handoff.", "collaboration.", "lease."].contains(where: action.hasPrefix) || action == "session.transfer" {
            return try AgentCollaboration.shared.execute(action, args)
        }
        if action == "machine.current" { return AgentIdentity.shared.machine }
        if action == "resource.version" { return try AgentVersions.read(args) }
        let coordination = AgentCollaboration.shared
        let info = (Self.catalog["actions"] as? [[String: Any]])?.first { $0["name"] as? String == action }
        let mutating = info?["readOnly"] as? Bool == false
        var resources: [String] = []
        if mutating, let session = args["session_id"] as? String {
            if !action.hasPrefix("timer.") { try coordination.checkSession(session) }
            resources.append((action.hasPrefix("timer.") ? "timer:" : "session:") + session)
        }
        if action == "clipboard.write" || args["clipboard"] as? Bool == true { resources.append("clipboard") }
        if mutating, ["item.", "note.", "task.", "theme."].contains(where: action.hasPrefix), let id = args["id"] as? String { resources.append("item:" + id) }
        var acquired: [String] = []
        defer { for resource in acquired { coordination.end(resource: resource) } }
        for resource in resources.sorted() { try coordination.begin(resource: resource, leaseID: args["lease_id"] as? String); acquired.append(resource) }
        try AgentVersions.validate(action, args: args, named: AgentContext.principal.id != "local")
        if ["recording.start", "meeting.start", "dictation.start"].contains(action) {
            try coordination.pruneSessions(active: Set([ScreenRecorder.shared.agentSessionID, meetings.activeCaptureMeetingID, voice.agentSessionID].compactMap { $0 }))
        }
        let result = try await execute(action, args)
        if ["recording.start", "meeting.start", "dictation.start"].contains(action), let session = (result as? [String: Any])?["session_id"] as? String {
            do { try coordination.ownSession(session) }
            catch { throw AgentError("OWNERSHIP_NOT_PERSISTED", "Capture started but ownership could not be saved. Use MyMan recording controls; do not start it again.", details: ["session": result]) }
        }
        if mutating {
            do { try coordination.completed(action: action, result: result) }
            catch {
                if var value = result as? [String: Any] { value["coordination_persisted"] = false; return value }
                return ["result": result, "coordination_persisted": false]
            }
        }
        return result
    }
    func execute(_ action: String, _ args: [String: Any]) async throws -> Any {
        let isAudio = (action.hasPrefix("recording.") && !["recording.status", "recording.frames", "recording.export", "recording.polish"].contains(action)) || action.hasPrefix("dictation.") || ["meeting.start", "meeting.stop", "meeting.discard"].contains(action)
        if isAudio { guard !audioCommand else { throw AgentError("BUSY", "An audio control command is in progress.") }; audioCommand = true }
        defer { if isAudio { audioCommand = false } }
        switch action {
        case "tool.evaluate", "timer.start", "timer.status", "timer.pause", "timer.resume", "timer.cancel", "timer.sound", "reminder.create", "reminder.list", "reminder.cancel", "reminder.sound", "calendar.list":
            return try await AgentQuickTools.execute(action, args)
        case "workflow.templates": return ["templates": AgentWorkflowTemplates.catalog, "host_sharing_verified": false]
        case "dictation.history": return ["entries": try WorkflowValues.json(Array(DictationHistory.shared.entries.prefix(args["limit"] as? Int ?? 20)))]
        case "dictation.correction":
            guard let entry = DictationHistory.shared.entries.first(where: { $0.id == args["id"] as? String }), (entry.correctedText ?? entry.text) == args["expected_text"] as? String else { throw AgentError("EDIT_CONFLICT", "Read the current dictation before saving a correction.") }
            try DictationHistory.shared.correct(entry.id, text: args["text"] as! String, human: false)
            return ["id": entry.id, "corrected": true, "vocabulary_learning": false]
        case "dictation.style":
            let bundle = args["bundle_id"] as! String
            let tone = args["tone"] as! String
            DictationAppStyles.set(tone == "default" ? nil : DictationTone(rawValue: tone), for: bundle)
            return ["bundle_id": bundle, "tone": tone]
        case "share.publish":
            let source = try item(args)
            guard source.revision == args["expected_revision"] as? Int else { throw AgentError("EDIT_CONFLICT", "Read the current capture before sharing.") }
            let receipt = try await SharePublishing.shared.publish(item: source, seconds: args["ttl_seconds"] as? Int ?? 86400, human: false)
            return ["id": receipt.id, "url": receipt.url, "expires_at": Self.date(receipt.expiresAt)]
        case "share.list": return ["shares": try WorkflowValues.json(SharePublishing.shared.receipts.filter { $0.owner == AgentContext.principal.id })]
        case "share.revoke": try await SharePublishing.shared.revoke(args["id"] as! String, human: false); return ["revoked": true]
        case "workflow.cancel":
            try WorkflowActivity.cancel(args["job_id"] as! String, false)
            return ["stop_requested": true, "job_id": args["job_id"]!]
        case "workflow.context": return try WorkflowContext.export(ids: args["ids"] as! [String])
        case "meeting.speaker":
            let source = try item(args)
            guard source.revision == args["expected_revision"] as? Int else { throw AgentError("EDIT_CONFLICT", "Read the current meeting before correcting a speaker.") }
            let updated = try MeetingDecisions.correctSpeaker(source: source, from: args["from"] as! String, to: args["to"] as! String)
            return ["id": updated.id, "revision": updated.revision, "message": "Transcript updated. Review existing notes for old speaker references."]
        case "workflow.handshake": return try WorkflowConnection.shared.handshake(args["challenge"] as! String)
        case "workflow.open": WorkflowCenter.shared.open(tab: args["tab"] as? String ?? "activity"); return ["opened": true]
        case "decision.list": return ["decisions": try WorkflowValues.json(MeetingDecisions.shared.decisions), "requires_source_review": true]
        case "decision.create":
            return ["decision": try WorkflowValues.json(MeetingDecisions.shared.add(sourceID: args["source_id"] as! String, revision: args["expected_revision"] as! Int, topic: args["topic"] as! String, text: args["text"] as! String, quote: args["quote"] as! String))]
        case "decision.followup": return ["draft_markdown": try MeetingDecisions.shared.followup(ids: args["ids"] as! [String], relatedIDs: args["related_ids"] as? [String] ?? []), "sent": false]
        case "capture.float": try FloatingReference.open(item(args)); return ["opened": true]
        case "capture.scroll.start":
            let region = args["region"] as! [String: Any]
            let id = try ScrollingCapture.shared.start(region: CGRect(x: region["x"] as! Double, y: region["y"] as! Double, width: region["width"] as! Double, height: region["height"] as! Double))
            return ["session_id": id, "state": "capturing", "scrolling": "user_or_host_controlled"]
        case "capture.scroll.status": return try ScrollingCapture.shared.status(id: args["session_id"] as! String)
        case "capture.scroll.stop": return try await ScrollingCapture.shared.finish(id: args["session_id"] as! String)
        case "capture.scroll.cancel": try ScrollingCapture.shared.cancel(id: args["session_id"] as! String); return ["cancelled": true]
        case "app.doctor":
            return ["permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "accessibility": AXIsProcessTrusted(), "calendar": EKEventStore.authorizationStatus(for: .event) == .fullAccess, "input_monitoring": "not_required"], "agents": AgentConsent.status(), "brain_root": Brain.root.path, "brain_available": FileManager.default.fileExists(atPath: Brain.root.appendingPathComponent("catalog.json").path), "screen_recording_supported": ScreenRecorder.isSupported, "pointer_control": "not_supported"] as [String: Any]
        case "windows.list":
            guard CGPreflightScreenCaptureAccess() else { throw AgentError("PERMISSION_REQUIRED", "Grant My Man Screen Recording permission first.") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return content.windows.map { ["id": String($0.windowID), "app": $0.owningApplication?.applicationName ?? "", "title": $0.title ?? "", "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], "coordinates": "quartz-global-top-left"] as [String: Any] }
        case "app.status":
            return ["launch_id": launchID, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    "screen_recording": try ScreenRecorder.shared.statusForAgent(),
                    "meeting": ["session_id": meetings.activeCaptureMeetingID as Any? ?? NSNull(), "phase": String(describing: meetings.phase), "processing": meetings.isTranscribing],
                    "dictation": ["phase": voicePhase, "session_id": voice.agentSessionID as Any? ?? NSNull()],
                    "permissions": ["screen_recording": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized],
                    "note_processing": MeetingNotesService.shared.stages,
                    "update_blockers": AppUpdateActivity.current(voice: voice, meetings: meetings).reasons] as [String: Any]
        case "app.open": openSurface(args["surface"] as! String); return ["opened": true]
        case "screens.list": return NSScreen.screens.map { screen in ["id": String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), "selector": "id:" + String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), "name": screen.localizedName, "frame": [screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height], "scale": screen.backingScaleFactor] as [String: Any] }
        case "screenshot.capture", "screenshot.capture_markup":
            let date = Date(), meetingID = capture.meetingIDProvider()
            let (image, region, scale, windowID) = try await capturedImage(args)
            let output = action == "screenshot.capture_markup" ? try await Self.annotationModel(image: image, path: "", args: args).renderFinal() : image
            var result = try saveImage(output, capturedAt: date, meetingID: meetingID, clipboard: args["clipboard"] as? Bool ?? false)
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
            let model = try await Self.annotationModel(image: image, path: source.sourcePath, args: args)
            guard CaptureLifecycle.exists(kind: "screenshot", id: source.sourceID), CaptureIndex.item(source.id)?.excluded == source.excluded else { throw AgentError("CONTENT_CHANGED", "Source was deleted or hidden during OCR; nothing was saved.") }
            let count = (args["annotations"] as? [Any])?.count ?? 0
            if args["dry_run"] as? Bool == true && args["preview"] as? Bool == true { throw AgentError("INVALID_ARGUMENTS", "Choose dry-run or preview.") }
            if args["preview"] as? Bool == true {
                guard args["clipboard"] as? Bool != true, args["open_editor"] as? Bool != true else { throw AgentError("INVALID_ARGUMENTS", "Preview cannot copy or open an editor.") }
                let artifact = try AgentMediaStore.shared.image(model.renderFinal())
                return ["preview": true, "source_id": source.id, "annotation_count": count, "attachment": artifact, "path": artifact["path"]!] as [String: Any]
            }
            if args["dry_run"] as? Bool == true { return ["valid": true, "source_id": source.id, "annotation_count": count] as [String: Any] }
            var result = try saveImage(model.renderFinal(), clipboard: args["clipboard"] as? Bool ?? false)
            result["source_id"] = source.id; result["annotation_count"] = count
            if args["open_editor"] as? Bool == true { capture.openInEditor(fileURL: URL(fileURLWithPath: result["path"] as! String)) }
            return result
        case "screenshot.import":
            let path = args["path"] as! String
            guard path.hasPrefix("/") else { throw AgentError("INVALID_ARGUMENTS", "Use an absolute image path.") }
            return try saveImage(AgentImages.load(URL(fileURLWithPath: path)))
        case "screenshot.image":
            let (_, image) = try shot(args); let png = try AgentImages.png(image)
            guard png.count <= 8 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Image exceeds 8 MiB; use the returned local path.") }
            return ["image": ["mimeType": "image/png", "data": png.base64EncodedString()]]
        case "screenshot.remove_background":
            let (source, image) = try shot(args); let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: source.sourcePath))
            model.removeBackground(); try await wait(120) { !model.isRemovingBackground }
            guard model.backgroundRemoved else { throw AgentError("NO_FOREGROUND", "No foreground object could be separated.") }
            return try saveImage(model.renderFinal(), clipboard: args["clipboard"] as? Bool ?? false)
        case "app.wait": return try await awaitReady(args)
        case "screenshot.compare":
            let (before, a) = try shot(["id": args["before_id"]!])
            let (after, b) = try shot(["id": args["after_id"]!])
            guard !before.excluded, !after.excluded else { throw AgentError("NOT_FOUND", "A comparison source is excluded.") }
            guard let acg = a.cgImage(forProposedRect: nil, context: nil, hints: nil), let bcg = b.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AgentError("INVALID_IMAGE", "Cannot decode comparison images.") }
            let ignored = try (args["ignore_rects"] as? [[Double]] ?? []).map { try AgentImages.rect($0) }
            let threshold = Int(args["threshold"] as? Double ?? 20)
            let difference = try await Task.detached(priority: .userInitiated) { try AgentComparison.difference(acg, bcg, ignored: ignored, threshold: threshold) }.value
            async let aLines = ImageAnalysis.textObservations(a)
            async let bLines = ImageAnalysis.textObservations(b)
            let changedText = await AgentComparison.changedText(before: aLines, after: bLines, size: AgentImages.size(a), ignored: ignored)
            guard CaptureIndex.item(before.id)?.revision == before.revision, CaptureIndex.item(after.id)?.revision == after.revision,
                  CaptureIndex.item(before.id)?.excluded == false, CaptureIndex.item(after.id)?.excluded == false else { throw AgentError("CONTENT_CHANGED", "A source changed during comparison. Select the current images again.") }
            let image = try AgentComparison.render(before: a, after: b, difference: difference, ignored: ignored)
            return ["before_id": before.id, "after_id": after.id, "coordinates": "image-pixels-top-left", "changed_pixels": difference.changed,
                    "compared_pixels": difference.compared, "change_ratio": difference.compared == 0 ? 0 : Double(difference.changed) / Double(difference.compared),
                    "threshold": threshold, "regions": difference.regions.prefix(200).map { [$0.minX, $0.minY, $0.width, $0.height] },
                    "total_regions": difference.regions.count, "truncated": difference.regions.count > 200, "changed_text": changedText,
                    "attachment": try AgentMediaStore.shared.image(image, prefix: "comparison"), "temporary": true] as [String: Any]
        case "screenshot.targets":
            let (source, image) = try shot(args)
            let observations = await ImageAnalysis.textObservations(image)
            let regions = args["granularity"] as? String == "word" ? AgentMarkup.words(observations, size: AgentImages.size(image)) : AgentMarkup.regions(observations, size: AgentImages.size(image))
            let matches = (args["query"] as? String).map { AgentMarkup.matches(regions, text: $0) } ?? regions
            return ["source_id": source.id, "coordinates": "image-pixels-top-left", "regions": matches.prefix(200).map(\.json), "total": matches.count, "truncated": matches.count > 200] as [String: Any]
        case "screenshot.ocr":
            let (_, image) = try shot(args); let analysis = await ImageAnalysis.analyze(image)
            let regions = AgentMarkup.regions(analysis.observations, size: AgentImages.size(image))
            return ["text": analysis.text, "coordinates": "image-pixels-top-left", "regions": zip(regions, analysis.observations).map { region, line in region.json.merging(["box": [line.box.minX, line.box.minY, line.box.width, line.box.height], "box_coordinates": "vision-normalized-bottom-left"]) { a, _ in a } }] as [String: Any]
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
            let windowID = args["window_id"] as? String
            guard windowID == nil || (args["display"] == nil && args["region"] == nil && args["coordinates"] == nil) else { throw AgentError("INVALID_ARGUMENTS", "Choose window-id or display/region.") }
            try await recorder.startForAgent(region: windowID == nil ? desktopRegion(args) : nil, windowID: windowID, maximumDuration: args["max_duration"] as? Double ?? 300, microphone: args["microphone"] as? Bool ?? false, systemAudio: args["system_audio"] as? Bool ?? true, webcam: args["webcam"] as? Bool ?? false, hideCursor: args["hide_cursor"] as? Bool ?? false)
            guard let id = recorder.agentSessionID else { throw AgentError("CAPTURE_FAILED", "Screen recording did not start.") }
            while !recorder.isRecording && recorder.isBusy { try await Task.sleep(for: .milliseconds(100)) }
            let status = try await recordingStatus(id)
            guard status["state"] as? String != "failed" else { throw AgentError("CAPTURE_FAILED", "Screen recording did not start.", details: ["session": status]) }
            return status
        case "recording.status":
            return try await recordingStatus(args["session_id"] as? String)
        case "recording.pause", "recording.resume":
            guard #available(macOS 15.0, *) else { throw AgentError("UNSUPPORTED", "Screen recording requires macOS 15 or later.") }
            let recorder = ScreenRecorder.shared; try session(args, recorder.agentSessionID)
            if action == "recording.pause" { try await recorder.pauseForAgent() } else { try await recorder.resumeForAgent() }
            return try recorder.statusForAgent(sessionID: args["session_id"] as? String)
        case "recording.frames":
            let source = try item(args)
            guard source.kind == "recording" else { throw AgentError("INVALID_ARGUMENTS", "Expected a recording ID.") }
            var result = try await AgentVideo.frames(URL(fileURLWithPath: source.sourcePath), args: args)
            result["source_id"] = source.id
            return result
        case "recording.export":
            let source = try item(args)
            guard source.kind == "recording" else { throw AgentError("INVALID_ARGUMENTS", "Expected a recording ID.") }
            let url = SettingsStore.shared.screenshotFolderURL.appendingPathComponent("Clip-\(UUID().uuidString).mp4")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try await AgentVideo.export(URL(fileURLWithPath: source.sourcePath), to: url, start: args["start"] as? Double ?? 0, end: args["end"] as? Double, maxBytes: (args["max_bytes"] as? Double).map(Int.init), edits: args["edits"] as? [[String: Any]] ?? [])
                guard CaptureIndex.item(source.id) != nil else { throw AgentError("CONTENT_CHANGED", "Source was deleted during export.") }
                // Zoom edits reframe the picture, so the cursor would no longer line up.
                if !((args["edits"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "zoom" }) {
                    RecordingSidecars.copyTrimmed(from: URL(fileURLWithPath: source.sourcePath), to: url, start: args["start"] as? Double ?? 0, end: args["end"] as? Double ?? .infinity)
                }
                let attachment = try await AgentVideo.attachment(url)
                guard CaptureIndex.item(source.id)?.excluded == source.excluded else { throw AgentError("CONTENT_CHANGED", "Source was deleted or hidden during export.") }
                let record = ScreenRecording(id: UUID().uuidString, path: url.path, duration: Int(ceil(attachment["duration"] as? Double ?? 0)), createdAt: Date())
                try await Database.shared.write { try record.insert($0) }
                Brain.syncRecording(id: record.id, filePath: record.path, duration: record.duration, transcript: "", createdAt: record.createdAt)
                return ["id": "recording-" + record.id, "kind": "recording", "state": "finalized", "source_id": source.id, "path": record.path, "attachment": attachment, "transcript_status": "not_generated", "edits_applied": (args["edits"] as? [Any])?.count ?? 0, "edit_time_origin": "source"] as [String: Any]
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        case "recording.polish":
            let source = try item(args)
            guard source.kind == "recording" else { throw AgentError("INVALID_ARGUMENTS", "Expected a recording ID.") }
            let movie = URL(fileURLWithPath: source.sourcePath)
            guard FileManager.default.fileExists(atPath: movie.path) else { throw AgentError("NOT_FOUND", "Recording file is missing.") }
            let plan = try AgentPolish.plan(AgentPolish.recipe(from: args))
            let clicks = ClickLog.load(for: movie), track = RecordingSidecars.loadCursor(for: movie)
            let size = try await AgentPolish.videoSize(movie)
            var options = plan.options, warnings: [String] = []
            if plan.cursor {
                if let track, track.separate, !track.samples.isEmpty { options.drawCursor = true }
                else if track == nil { warnings.append("No cursor track was saved with this recording (window recordings have none), so no cursor was drawn.") }
                else { warnings.append("This recording already shows the system cursor, so no second cursor was drawn. Start with record start --hide-cursor to get a smooth drawn cursor.") }
            }
            if plan.autoZoom && clicks.isEmpty { warnings.append("No clicks were recorded, so auto-zoom found nothing to zoom on. Add recipe.zoom.moments to zoom by hand.") }
            // Captions on a backdrop sit in a band under the video, never over the app.
            if plan.background != nil, !plan.captions.isEmpty {
                options.captionBand = DemoFinish.captionBand(videoHeight: size.height, padding: RecordingPolish.frame(for: size, options: options).padding)
            }
            let windows: [ZoomTimeline.Window]? = plan.moments.isEmpty ? nil : AgentPolish.windows(plan.moments, size: size)
            let frame = plan.reframes ? RecordingPolish.frame(for: size, options: options) : RecordingPolish.Frame(source: size, padding: 0, output: size)
            let zooms = plan.zoom ? (windows ?? ZoomTimeline.windows(for: clicks)).count : 0
            let voice = await DemoFinish.hasAudio(movie)
            if let music = plan.music, voice, music.duck {
                warnings.append("On the Mac the music plays at a lower level under the recording's audio; it does not duck while someone speaks yet.")
            }
            var summary: [String: Any] = ["recipe": plan.recipe, "zoom_moments": zooms, "clicks": clicks.count, "cursor_drawn": options.drawCursor,
                                          "background": plan.background.map { $0 as Any } ?? NSNull(), "source_size": [Double(size.width), Double(size.height)],
                                          "output_size": [Double(frame.output.width), Double(frame.output.height)], "warnings": warnings,
                                          "audio": plan.music != nil ? (voice ? "recording audio with music" : "music") : (voice ? "recording audio" : "none")]
            if let music = plan.music {
                var about: [String: Any] = ["volume": DemoFinish.volume(music, recordingHasAudio: voice), "ducked_under_recording_audio": false]
                if let name = music.track { about["track"] = name; about["license"] = "CC0-1.0 (composed by MyMan from code; no samples)" }
                else { about["file"] = music.file; about["license"] = "your file" }
                summary["music"] = about
            }
            if plan.title != nil || plan.end != nil {
                let t = plan.title?.seconds ?? 0, e = plan.end?.seconds ?? 0
                summary["cards"] = ["title_seconds": t, "end_seconds": e, "video_starts_at": t]
                let length = try await AVURLAsset(url: movie).load(.duration).seconds
                summary["duration"] = ((t + e + length) * 100).rounded() / 100
            }
            if !plan.captions.isEmpty { summary["captions"] = plan.captions.count }
            if args["dry_run"] as? Bool == true { return summary.merging(["source_id": source.id, "dry_run": true]) { a, _ in a } }
            let url = SettingsStore.shared.screenshotFolderURL.appendingPathComponent("Polished-\(UUID().uuidString).mp4")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("myman-polish-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                var stage = movie
                if plan.reframes {
                    stage = plan.finishes ? work.appendingPathComponent("reframed.mp4") : url
                    try await RecordingPolish.export(source: movie, to: stage, options: options, clicks: clicks, cursor: track, zoomWindows: windows)
                }
                if plan.finishes {
                    // On a backdrop, captions are centred in the space under the video.
                    let captionPlace = options.captionBand > 0 ? CGRect(x: 0, y: 0, width: frame.output.width, height: frame.padding + frame.band) : nil
                    let done = try await DemoFinish.finish(input: stage, to: url, title: plan.title, end: plan.end, music: plan.music,
                                                           captions: plan.captions, captionPlace: captionPlace, captionText: size, options: options, work: work)
                    summary.merge(done) { _, new in new }
                }
                guard CaptureIndex.item(source.id)?.excluded == source.excluded else { throw AgentError("CONTENT_CHANGED", "Source was deleted or hidden during polish.") }
                let attachment = try await AgentVideo.attachment(url)
                let record = ScreenRecording(id: UUID().uuidString, path: url.path, duration: Int(ceil(attachment["duration"] as? Double ?? 0)), createdAt: Date())
                try await Database.shared.write { try record.insert($0) }
                Brain.syncRecording(id: record.id, filePath: record.path, duration: record.duration, transcript: "", createdAt: record.createdAt)
                return summary.merging(["id": "recording-" + record.id, "kind": "recording", "state": "finalized", "source_id": source.id, "path": record.path, "attachment": attachment]) { a, _ in a }
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        case "demo.run": return try await runDemo(args)
        case "recording.cancel":
            let recorder = ScreenRecorder.shared; try session(args, recorder.agentSessionID)
            try await recorder.cancelForAgent(); return ["cancelled": true]
        case "recording.stop":
            let recorder = ScreenRecorder.shared
            let id = args["session_id"] as! String
            if id == recorder.agentSessionID {
                recorder.stop()
                try await wait(180) { !recorder.isBusy || recorder.sessionError != nil }
            }
            let result = try await recordingStatus(id)
            guard result["state"] as? String == "finalized" else {
                throw AgentError("SAVE_FAILED", "Recording is not finalized; inspect record status for this session.", details: ["session": result])
            }
            return result
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
        case "note.attach": return try AgentNoteAssets.attach(args)
        case "capture.search":
            let enabled = UserDefaults.standard.object(forKey: "captureSemanticSearch") as? Bool ?? true
            return try await Task.detached(priority: .userInitiated) { try AgentSearch.run(args, semanticEnabled: enabled) }.value
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
        case "item.rename": let source = try item(args); try CaptureLifecycle.rename(source, title: args["title"] as! String, expectedRevision: args["expected_revision"] as? Int); return ["id": source.id]
        case "item.pin": let source = try item(args); if source.pinned != args["pinned"] as! Bool { try CaptureLifecycle.pin(source, expectedRevision: args["expected_revision"] as? Int) }; return ["id": source.id]
        case "item.exclude": let source = try item(args); try CaptureLifecycle.exclude(source, excluded: args["excluded"] as! Bool, expectedRevision: args["expected_revision"] as? Int); return ["id": source.id]
        case "item.delete": let source = try item(args); try CaptureLifecycle.delete(source, expectedRevision: args["expected_revision"] as? Int); return ["deleted": source.id]
        case "item.related": return try RelatedItems.items(for: item(args).id).map { ["item": Self.json($0.item), "score": $0.score, "reason": $0.reason] as [String: Any] }
        case "theme.rename", "theme.pin", "theme.dismiss", "theme.assign", "theme.merge":
            let id = args["id"] as! String
            guard try Database.shared.read({ try Row.fetchOne($0, sql: "SELECT id FROM captureTheme WHERE id = ?", arguments: [id]) }) != nil else { throw AgentError("NOT_FOUND", "Theme not found.") }
            switch action {
            case "theme.rename": try ThemeStore.rename(id, title: args["title"] as! String, expectedVersion: args["expected_version"] as? String)
            case "theme.pin": try ThemeStore.pin(id, pinned: args["pinned"] as! Bool, expectedVersion: args["expected_version"] as? String)
            case "theme.dismiss": try ThemeStore.dismiss(id, expectedVersion: args["expected_version"] as? String)
            case "theme.assign": _ = try item(["id": args["item_id"]!]); try ThemeStore.assign(args["item_id"] as! String, to: id, remove: args["remove"] as? Bool ?? false, expectedVersion: args["expected_version"] as? String)
            default:
                let target = args["target_id"] as! String
                guard try Database.shared.read({ try Row.fetchOne($0, sql: "SELECT id FROM captureTheme WHERE id = ? AND dismissed = 0", arguments: [target]) }) != nil else { throw AgentError("NOT_FOUND", "Target theme not found.") }
                try ThemeStore.merge(id, into: target, expectedVersion: args["expected_version"] as? String, targetVersion: args["target_version"] as? String)
            }; return ["id": id]
        case "task.create", "task.update", "task.delete":
            var task: TaskItem
            if action == "task.create" { task = TaskItem(id: UUID().uuidString, title: args["title"] as! String, source: "manual", done: false, createdAt: Date()) }
            else { guard let found = try await Database.shared.read({ try TaskItem.fetchOne($0, key: args["id"] as! String) }) else { throw AgentError("NOT_FOUND", "Task not found.") }; task = found }
            let expectedTaskVersion = args["expected_version"] as? String
            if action == "task.delete" { let taskID = task.id; try await Database.shared.write { try AgentVersions.check("task", id: taskID, expected: expectedTaskVersion, db: $0); _ = try TaskItem.deleteOne($0, key: taskID) } }
            else {
                if let title = args["title"] as? String { task.title = title }
                if let notes = args["notes"] as? String { task.notes = notes }
                if let done = args["done"] as? Bool, done != task.done { task.done = done; task.completedAt = done ? Date() : nil }
                if let due = args["due"] as? String { guard let date = ISO8601DateFormatter().date(from: due) else { throw AgentError("INVALID_ARGUMENTS", "due must be ISO 8601 with timezone.") }; task.dueDate = date }
                if args["clear_due"] as? Bool == true { task.dueDate = nil }
                let updated = task; try await Database.shared.write {
                    if action != "task.create" { try AgentVersions.check("task", id: updated.id, expected: expectedTaskVersion, db: $0) }
                    try updated.save($0)
                }
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
        case "font.create", "font.match":
            let (source, image) = try shot(args); image.size = AgentImages.size(image)
            guard !source.excluded else { throw AgentError("NOT_FOUND", "Source screenshot is excluded.") }
            let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: source.sourcePath))
            if let values = args["region"] as? [Double] { let region = try AgentImages.rect(values); guard CGRect(origin: .zero, size: image.size).contains(region), region.width > 10, region.height > 10 else { throw AgentError("INVALID_ARGUMENTS", "Select a text region within the screenshot.") }; model.applyCrop(region) }
            if action == "font.match" { return try await FontWorkbenchController.matchForAgent(image: model.image, title: source.title, sourceID: source.id) }
            return try await FontWorkbenchController.generateForAgent(image: model.image, title: source.title, sourceID: source.id, name: args["name"] as! String, capturedOnly: args["captured_only"] as? Bool ?? false)
        case "font.file", "font.preview", "font.quality":
            let source = try item(args); guard source.kind == "note", FontProjectStore.exists(source.sourceID) else { throw AgentError("NOT_FOUND", "Saved font not found.") }
            return try AgentFonts.file(noteID: source.sourceID, text: args["text"] as? String)
        case "font.open":
            let source = try item(args)
            if source.kind == "screenshot" { FontWorkbenchController.open(image: try shot(args).1, sourceURL: URL(fileURLWithPath: source.sourcePath)) }
            else if source.kind == "note" { try FontWorkbenchController.openProject(noteID: source.sourceID) }
            else { throw AgentError("INVALID_ARGUMENTS", "Expected a screenshot or saved font note.") }
            return ["opened": source.id]
        default: throw AgentError("UNKNOWN_ACTION", "Action not implemented.")
        }
    }
    static func annotationModel(image: NSImage, path: String, args: [String: Any]) async throws -> EditorModel {
            let size = AgentImages.size(image); image.size = size
            let model = EditorModel(image: image, fileURL: URL(fileURLWithPath: path), persistPreferences: args["preview"] as? Bool != true && args["dry_run"] as? Bool != true)
            let annotations = args["annotations"] as? [[String: Any]] ?? []
            let needsOCR = annotations.contains { $0["target_text"] != nil || $0["target_region"] != nil }
            let observations = needsOCR ? await ImageAnalysis.textObservations(image) : []
            let regions = AgentMarkup.regions(observations, size: size) + AgentMarkup.words(observations, size: size)
            var occupied: [CGRect] = []
            var calloutNumber = 0
            if let color = args["color"] as? String { model.annotationColor = AgentImages.color(color) }
            for input in annotations {
                let annotation = try AgentMarkup.resolve(input, regions: regions, size: size)
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
                    case "circle":
                        model.overlayImages[id] = try AgentMarkup.circle(size: rect.size, color: model.annotationColors[id] ?? model.annotationColor)
                        model.add(.image(id: id, rect: rect))
                    case "callout":
                        calloutNumber += 1
                        let number = annotation["number"] as? Double ?? Double(calloutNumber)
                        guard number.rounded() == number else { throw AgentError("INVALID_ARGUMENTS", "Callout numbers must be integers.") }
                        let label = String(Int(number)) + ((annotation["text"] as? String).map { ". " + $0 } ?? "")
                        let badge = try AgentMarkup.badge(label, fontSize: model.annotationFontSizes[id] ?? min(32, model.annotationFontSize), color: model.annotationColors[id] ?? model.annotationColor)
                        let labelRect = try AgentMarkup.labelRect(size: AgentImages.size(badge), target: rect, canvas: size, occupied: occupied)
                        occupied.append(labelRect)
                        model.add(.box(id: id, rect: rect))
                        let labelID = UUID(); model.overlayImages[labelID] = badge; model.add(.image(id: labelID, rect: labelRect))
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
    private func recordingStatus(_ id: String?) async throws -> [String: Any] {
        var result = try ScreenRecorder.shared.statusForAgent(sessionID: id)
        if let session = result["session_id"] as? String { result["owner"] = AgentCollaboration.shared.sessionOwner(session) as Any? ?? NSNull() }
        if result["state"] as? String == "finalized", let path = result["path"] as? String {
            result["kind"] = "recording"
            result["attachment"] = try await AgentVideo.attachment(URL(fileURLWithPath: path))
        }
        return result
    }
    private func saveImage(_ image: NSImage, capturedAt: Date = Date(), meetingID: String? = nil, clipboard: Bool = false) throws -> [String: Any] {
        var result = try capture.saveAgentImage(image, capturedAt: capturedAt, meetingID: meetingID, clipboard: clipboard)
        result["attachment"] = AgentMediaStore.imageAttachment(image, path: result["path"] as! String)
        return result
    }
    private var voicePhase: String { switch voice.phase { case .idle: return "idle"; case .recording: return "recording"; case .preparing: return "preparing"; case .transcribing: return "transcribing"; case .done: return "done" } }
    static func date(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func json(_ item: CaptureItem) -> [String: Any] { ["id": item.id, "kind": item.kind, "title": item.title, "body": item.body, "summary": item.summary, "path": item.sourcePath, "captured_at": date(item.capturedAt), "updated_at": date(item.modifiedAt), "pinned": item.pinned, "excluded": item.excluded, "revision": item.revision] }
}

/// Small validator for the deliberately limited JSON Schema subset in actions.json.
/// Both CLI/MCP and the native boundary validate; callers cannot bypass schemas.
enum AgentSchema {
    static func validate(_ value: Any, schema: [String: Any], path: String = "arguments") throws {
        func fail() throws -> Never { throw AgentError("INVALID_ARGUMENTS", "Invalid \(path); inspect the action schema.") }
        switch schema["type"] as? String {
        case "object":
            // An object schema without properties (a polish recipe, a demo script)
            // is free-form here; its action checks every key itself.
            if schema["properties"] == nil { guard value is [String: Any] else { try fail() }; return }
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
        case "number", "integer":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? -.greatestFiniteMagnitude),
                  n.doubleValue <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude) else { try fail() }
            if schema["type"] as? String == "integer", n.doubleValue.rounded(.towardZero) != n.doubleValue { try fail() }
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
            note.body = body
            if note.meetingID == nil { note.title = Note.deriveTitle(from: body) }
            note.updatedAt = Date()
            try note.update(db); return note
        }
        Brain.syncNote(id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
