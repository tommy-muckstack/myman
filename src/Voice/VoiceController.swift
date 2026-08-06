import AppKit
import AVFoundation
import SwiftUI

// Dictation: ⌥⇧V toggles. A small pill appears bottom-center with a live
// waveform; toggling again (or clicking the pill) stops, transcribes, and
// types into the currently focused control when transcription finishes. The pill then lingers ~60s offering
// "Save as note" before quietly disappearing.

@MainActor
final class VoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(Double) // model download progress 0...1
        case recording
        case transcribing
        case done(String)

        var pasted: Bool {
            if case .done = self { return AXIsProcessTrusted() }
            return false
        }
    }

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = []

    private let audio = AudioCapture.shared
    private var session: UUID?
    private var panel: FloatingPanel?
    private var levelTimer: Timer?
    private var hasDetectedSpeech = false
    private var silenceBegan: Date?
    /// Energy endpointing: once you've spoken, sustained quiet auto-stops the
    /// recording. The threshold ADAPTS to this session's peak level (raw,
    /// ungained capture runs much quieter than the old 3x-boosted meter) and
    /// never fires while the hotkey is physically held — release is the
    /// endpoint in push-to-talk.
    private var sessionPeakLevel: Float = 0
    private let silenceAutoStop: TimeInterval = 2.5
    private var hotkeyHeld = false

    private var silenceThreshold: Float {
        max(0.0035, sessionPeakLevel * 0.12)
    }
    private var lingerTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    private var pressBegan: Date?
    private var escHotkeyID: UInt32?
    /// Why the recording ended — silence / release / toggle / pill.
    private var endReason = "unknown"
    private let notes = NotesStore()

    func toggle() {
        switch phase {
        case .idle, .done:
            start()
        case .recording:
            endReason = "toggle"
            stopAndTranscribe()
        case .preparing, .transcribing:
            break
        }
    }

    /// Push-to-talk: hold ⌥⇧V to speak, release to transcribe + paste.
    /// A quick tap (<0.4s) falls back to toggle behavior.
    func hotkeyDown() {
        pressBegan = Date()
        hotkeyHeld = true
        toggle()
    }

    /// Bare-modifier hold: release always ends it — a short hold (a normal
    /// ⌘-tap) cancels silently instead of toggling into hands-free mode.
    func modifierHotkeyUp() {
        hotkeyHeld = false
        guard case .recording = phase else { return }
        if let began = pressBegan, Date().timeIntervalSince(began) > 0.4 {
            endReason = "release"
            stopAndTranscribe()
        } else {
            dismiss()
        }
    }

    /// Another key was pressed while the modifier was held (⌘C etc.) —
    /// that was a shortcut, not dictation.
    func modifierHotkeyCancelled() {
        hotkeyHeld = false
        if case .recording = phase {
            dismiss()
        }
    }

    func hotkeyUp() {
        hotkeyHeld = false
        guard case .recording = phase,
              let began = pressBegan,
              Date().timeIntervalSince(began) > 0.4
        else { return }
        endReason = "release"
        stopAndTranscribe()
    }

    /// Pre-warm the audio engine so the first hotkey press is instant.
    /// Off the main thread: setVoiceProcessingEnabled can block for seconds
    /// on some machines, and doing that during launch was MYMAN-2's 3s hang.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [audio] in
            audio.prepare()
        }
    }

    private func start() {
        lingerTask?.cancel()
        // Keep the starting app only as cleanup context; delivery targets
        // whichever focused control the user has when transcription finishes.
        targetApp = NSWorkspace.shared.frontmostApplication

        // Pill appears the instant the key goes down — everything else is
        // behind it, not in front of it.
        showPill()

        // Ask for Accessibility ONCE (auto-paste); after that, check silently —
        // without the grant, results just land on the clipboard.
        let promptedKey = "promptedAccessibility"
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
        }

        // Already authorized (the normal case): no async permission
        // round-trip — that callback alone was visible lag.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Task { @MainActor in await self.startAuthorized() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        await self.startAuthorized()
                    } else {
                        self.dismissPill()
                        self.phase = .idle
                    }
                }
            }
        default:
            dismissPill()
            phase = .idle
        }
    }

    private func startAuthorized() async {
        let wanted = TranscriptionService.shared.dictationKind
        if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != wanted {
            phase = .preparing(0)
            await TranscriptionService.shared.load(kind: wanted) { progress in
                Task { @MainActor in
                    if case .preparing = self.phase { self.phase = .preparing(progress) }
                }
            }
        }
        // If a call app already owns the mic (Zoom, Meet, …), our voice
        // processing would corrupt what the other side hears — join raw.
        let othersOnMic = AudioCapture.processesUsingMic()
            .contains { $0 != Bundle.main.bundleIdentifier }
        do {
            session = try audio.begin(othersOnMic ? .raw : .voiceProcessed)
        } catch {
            NSLog("My Man [Voice] mic start failed: \(error)")
            dismissPill()
            phase = .idle
            return
        }
        phase = .recording
        recenterPill()
        // Esc finishes the take (stop → transcribe → paste). Registered only
        // while recording so Esc stays normal everywhere else.
        if case .success(let id) = HotkeyCenter.shared.register(
            .init(keyCode: 53, modifiers: 0),
            handler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, case .recording = self.phase else { return }
                    self.endReason = "esc"
                    self.stopAndTranscribe()
                }
            }
        ) {
            escHotkeyID = id
        }
        hasDetectedSpeech = false
        silenceBegan = nil
        sessionPeakLevel = 0
        Analytics.track("dictation_started", ["engine": TranscriptionService.shared.kind.rawValue])
        levels = Array(repeating: 0, count: 24)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.phase else { return }
                let level = self.session.map { self.audio.currentLevel(for: $0) } ?? 0
                self.sessionPeakLevel = max(self.sessionPeakLevel, level)
                // Bars scale to THIS session's peak — a whisper still dances.
                let display = min(1, level / max(self.sessionPeakLevel, 0.006))
                var next = self.levels
                next.removeFirst()
                next.append(display)
                self.levels = next
                // Silence endpointing: speak → pause → it pastes itself.
                // Never while the hotkey is held — release is the endpoint.
                if self.hotkeyHeld {
                    self.silenceBegan = nil
                } else if level > self.silenceThreshold {
                    self.hasDetectedSpeech = true
                    self.silenceBegan = nil
                } else if self.hasDetectedSpeech {
                    if let began = self.silenceBegan {
                        if Date().timeIntervalSince(began) >= self.silenceAutoStop {
                            self.endReason = "silence"
                            self.stopAndTranscribe()
                        }
                    } else {
                        self.silenceBegan = Date()
                    }
                }
            }
        }
    }

    /// The quietest 0.15s frame in the window around the ideal chunk edge —
    /// splitting speech at silence keeps every word in exactly one chunk.
    private static func silenceAlignedEnd(samples: [Float], from index: Int,
                                          chunkSamples: Int) -> Int {
        let ideal = index + chunkSamples
        guard ideal < samples.count else { return samples.count }
        let searchStart = max(index + 16000 * 5, ideal - 16000 * 6)
        let searchEnd = min(ideal + 16000 * 2, samples.count)
        let frame = 2400 // 0.15s
        var best = ideal
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = searchStart
        while i + frame <= searchEnd {
            var sum: Float = 0
            for sample in samples[i..<(i + frame)] { sum += sample * sample }
            if sum < bestEnergy {
                bestEnergy = sum
                best = i + frame / 2
            }
            i += frame
        }
        return best
    }

    private func stopAndTranscribe() {
        if let escHotkeyID {
            HotkeyCenter.shared.unregister(escHotkeyID)
            self.escHotkeyID = nil
        }
        levelTimer?.invalidate()
        levelTimer = nil
        phase = .transcribing
        recenterPill()
        let samples = session.map { audio.end($0) } ?? []
        session = nil

        guard samples.count > 3200 else { // < 0.2s — nothing said
            dismissPill()
            phase = .idle
            return
        }

        Task { @MainActor in
            // Long takes NEVER go to the ASR in one piece — models sized for
            // utterances hang or truncate on minutes of audio. 60s chunks,
            // like meetings.
            // Qwen3 is built for ~30s utterances — longer chunks silently
            // truncate their tails (the "long dictation drops words" bug).
            // Parakeet handles 60s comfortably.
            let chunkSeconds = TranscriptionService.shared.kind == .qwen3 ? 30 : 60
            let rawText: String
            if samples.count > Int(Double(16000 * chunkSeconds) * 1.25) {
                var parts: [String] = []
                var index = 0
                while index < samples.count {
                    // Cut at the quietest moment near the boundary, never
                    // mid-word — hard cuts amputated phrases on both sides.
                    let end = Self.silenceAlignedEnd(
                        samples: samples, from: index, chunkSamples: 16000 * chunkSeconds)
                    let piece = await TranscriptionService.shared.transcribe(Array(samples[index..<end]))
                    if !piece.isEmpty { parts.append(piece) }
                    index = end
                }
                rawText = parts.joined(separator: " ")
            } else {
                rawText = await TranscriptionService.shared.transcribe(samples)
            }
            guard !rawText.isEmpty else {
                // >5s of speech that transcribed to nothing is a FAILURE, not
                // silence — keep the audio and say so. Never silently eat a take.
                if samples.count > 16000 * 5 {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss" // fixed: locale slashes break paths
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("MyMan/dictation-recovery", isDirectory: true)
                        .appendingPathComponent("dictation \(formatter.string(from: Date())).wav")
                    if let writer = WavWriter(url: url) {
                        writer.append(samples)
                        _ = writer.close()
                    }
                    Analytics.track("dictation_transcription_failed",
                                    ["duration_s": samples.count / 16000])
                    Toast.show("Transcription failed — audio saved",
                               actionLabel: "Show",
                               action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                }
                dismissPill()
                phase = .idle
                return
            }
            let text = await DictationCleanup.clean(rawText, targetBundleID: targetApp?.bundleIdentifier)
            pasteText(text)
            // History, not a note: dictations are throwaway-but-recoverable.
            try? await Database.shared.write { db in
                try db.execute(
                    sql: "INSERT INTO dictation (id, text, createdAt) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, rawText, Date()])
                try db.execute(sql: """
                    DELETE FROM dictation WHERE id NOT IN
                    (SELECT id FROM dictation ORDER BY createdAt DESC LIMIT 200)
                    """)
            }
            TaskExtractor.run(text: text, source: .dictation)
            Analytics.track("dictation_completed", [
                "chars": text.count,
                "duration_s": Int(samples.count / 16000),
                "engine": TranscriptionService.shared.kind.rawValue,
                "end_reason": endReason,
                "cleanup_changed": text != rawText,
                "auto_pasted": AXIsProcessTrusted(),
            ])
            phase = .done(text)
            if let panel {
                panel.layoutIfNeeded()
                presentBottomCenter(panel)
            }
            // If the text could only reach the clipboard, make the fix
            // unmissable.
            if !AXIsProcessTrusted() {
                AutoPasteSetupController.shared.showIfNeeded()
            }
            // Brief linger for "save as note", then gone — but hovering LOCKS
            // it open (same contract as the screenshot preview): stays while
            // the cursor is on it, short grace after leaving.
            lingerTask?.cancel()
            lingerTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                while self.resultHovered {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if !self.resultHovered {
                        try? await Task.sleep(for: .seconds(1.5)) // grace after leaving
                    }
                }
                guard !Task.isCancelled, case .done = self.phase else { return }
                self.dismissPill()
                self.phase = .idle
            }
        }
    }

    func saveAsNote() {
        guard case .done(let text) = phase else { return }
        notes.save(body: text, source: "dictation")
        lingerTask?.cancel()
        dismissPill()
        phase = .idle
    }

    func dismiss() {
        if let escHotkeyID {
            HotkeyCenter.shared.unregister(escHotkeyID)
            self.escHotkeyID = nil
        }
        lingerTask?.cancel()
        if case .recording = phase {
            if let session { _ = audio.end(session) }
            session = nil
            levelTimer?.invalidate()
            levelTimer = nil
        }
        dismissPill()
        phase = .idle
    }

    // MARK: Pill panel

    /// Drives the center-out appear / collapse-in dismiss of the pill.
    @Published var pillPresented = false
    /// Hovering the result card locks it open.
    var resultHovered = false

    private func showPill() {
        guard panel == nil else { return }
        pillPresented = false
        let pill = FloatingPanel(content: VoicePillView(controller: self), fixedSize: true)
        // The pill must never steal key focus — the user is dictating into
        // another app. FloatingPanel dismisses on resignKey; this panel never
        // becomes key, so disable that path by presenting without makeKey.
        pill.onDismiss = { [weak self] in self?.panel = nil }
        panel = pill
        presentBottomCenter(pill)
        DispatchQueue.main.async { [weak self] in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                self?.pillPresented = true
            }
        }
    }

    private func presentBottomCenter(_ panel: FloatingPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Estimate first (window owns its size), correct from the real
        // rendered size on the next runloop — bottom edge stays anchored.
        let estimate = { () -> NSSize in
            if case .done = self.phase { return NSSize(width: 456, height: 240) }
            return NSSize(width: 300, height: 72)
        }()
        panel.setFrame(
            NSRect(x: visible.midX - estimate.width / 2, y: visible.minY + 40,
                   width: estimate.width, height: estimate.height),
            display: true
        )
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.layoutIfNeeded()
            let size = panel.contentIdeal
            guard size.width > 1, size.height > 1,
                  abs(panel.frame.width - size.width) > 2
                      || abs(panel.frame.height - size.height) > 2 else { return }
            panel.setFrame(
                NSRect(x: visible.midX - size.width / 2, y: visible.minY + 40,
                       width: size.width, height: size.height),
                display: true
            )
        }
    }

    private func recenterPill() {
        guard let panel else { return }
        panel.layoutIfNeeded()
        presentBottomCenter(panel)
    }

    private func dismissPill() {
        guard let closing = panel else { return }
        panel = nil
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            pillPresented = false
        }
        // Let the collapse play before the window vanishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            closing.orderOut(nil)
        }
    }
}

struct VoicePillView: View {
    @ObservedObject var controller: VoiceController
    @State private var hoveringResult = false

    private let pillBlack = Color(red: 0.07, green: 0.07, blue: 0.08)

    var body: some View {
        Group {
            switch controller.phase {
            case .idle:
                EmptyView()

            case .preparing, .recording, .transcribing:
                // Wispr-style pill: black capsule, white bars, nothing else.
                HStack(spacing: 0) {
                    if case .preparing(let progress) = controller.phase {
                        ProgressView(value: max(0.02, progress))
                            .frame(width: 56)
                            .tint(.white)
                    } else if case .transcribing = controller.phase {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        waveform
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(Capsule().fill(pillBlack))
                .overlay(alignment: .bottom) {
                    if case .transcribing = controller.phase {
                        MovingBar()
                            .padding(.horizontal, 18)
                            .padding(.bottom, 5)
                    }
                }
                .onTapGesture {
                    if case .recording = controller.phase { controller.toggle() }
                }

            case .done(let text):
                // Wispr-style result card: icon / status / ×, transcript, Copy.
                // Hovering locks it open (screenshot-preview contract).
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        IconView(icon: .voice, size: 15, color: .white)
                        Spacer()
                        Text(AXIsProcessTrusted() ? "Pasted" : "Copied — ⌘V to paste")
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(Color(white: 0.62))
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(white: 0.75))
                            .frame(width: 24, height: 24)
                            .background(Circle().strokeBorder(Color(white: 0.35), lineWidth: 1))
                            .clickable(minSize: 26)
                            .onTapGesture { controller.dismiss() }
                    }
                    Text(text)
                        .font(MM.Fonts.bodyInput)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button {
                            controller.saveAsNote()
                        } label: {
                            HStack(spacing: 5) {
                                IconView(icon: .note, size: 12, color: Color(white: 0.62))
                                Text("Save as note")
                            }
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(Color(white: 0.62))
                            .clickable(minSize: 24)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        } label: {
                            Text("Copy")
                                .font(MM.Fonts.body)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(white: 0.42)))
                                .clickable(minSize: 26)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(pillBlack))
                .overlay(alignment: .bottom) {
                    // Drains in sync with the 3s auto-dismiss; hidden once
                    // hover locks the card open.
                    if !hoveringResult {
                        CountdownBar(duration: 3, color: .white.opacity(0.3))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }
                }
                .onHover { hovering in
                    hoveringResult = hovering
                    controller.resultHovered = hovering
                }
            }
        }
        .animation(MM.Motion.gentle, value: controller.phase)
        // Center-out on appear, collapse-in on dismiss.
        .scaleEffect(controller.pillPresented ? 1 : 0.4)
        .opacity(controller.pillPresented ? 1 : 0)
    }

    /// White bars rising from a center baseline, Wispr-style.
    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(controller.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: 3 + CGFloat(min(1, level)) * 15)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: controller.levels)
    }
}

/// Slim indeterminate progress bar for the pill's transcribing state.
private struct MovingBar: View {
    @State private var slid = false

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: geo.size.width * 0.3, height: 2)
                .offset(x: slid ? geo.size.width * 0.7 : 0)
        }
        .frame(height: 2)
        .background(Capsule().fill(.white.opacity(0.15)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                slid = true
            }
        }
    }
}
