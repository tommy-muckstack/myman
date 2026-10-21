import AppKit
import AVFoundation
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// An explicitly local bridge to the companion Chatterbox voice process,
/// which binds to localhost only. (Chat answers themselves are on-device
/// unless the user turns on the hosted writing model under Settings → AI.)
enum Chatterbox {
    private static let endpoint = URL(string: "http://127.0.0.1:8000")!
    private static var serverProcess: Process?
    private struct Request: Encodable {
        let model = "chatterbox"
        let input: String
        let voice = "default"
        let response_format = "wav"
    }

    static func synthesize(_ text: String) async throws -> Data {
        let url = endpoint.appending(path: "v1/audio/speech")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(input: text))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func installAndStart() async throws {
        guard let install = helper(named: "install-chatterbox", extension: "sh"),
              let run = helper(named: "run-chatterbox", extension: "sh") else {
            throw NSError(domain: "MyMan.Chatterbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Voice-reply installer is missing from this app."])
        }
        try await runShell(install)
        if !(await isReady()) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [run.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try AppChildProcesses.shared.run(process)
            serverProcess = process
        }
        for _ in 0..<90 { // package + model startup can take a little while
            if await isReady() { return }
            try? await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "MyMan.Chatterbox", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Chatterbox didn’t finish starting. Try again in a moment."])
    }

    private static func helper(named name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/\(name).\(ext)")
    }

    static func isReady() async -> Bool {
        var request = URLRequest(url: endpoint.appending(path: "health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private static func runShell(_ script: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: "MyMan.Chatterbox", code: Int(process.terminationStatus))) }
            }
            do { try AppChildProcesses.shared.run(process) } catch { continuation.resume(throwing: error) }
        }
    }
}

/// One tap starts an auto-turn conversation. We deliberately stop capture
/// while speaking so the reply cannot get transcribed back into the Brain.
@MainActor
final class BrainChatVoiceController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable { case idle, preparing, listening, transcribing, speaking, unavailable }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels = Array(repeating: Float(0), count: 16)
    @Published private(set) var status = ""
    @Published private(set) var needsVoiceSetup = false
    @Published private(set) var isInstallingVoice = false
    var onTranscript: ((String) -> Void)?

    private let audio = AudioCapture.shared
    private var session: UUID?
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var heardSpeech = false
    private var silenceSince: Date?
    private var peak: Float = 0
    private var shouldContinue = false
    private var pendingSpeech = ""

    private var threshold: Float { max(0.0035, peak * 0.12) }

    func checkVoiceReplies() {
        Task { @MainActor in
            needsVoiceSetup = !(await Chatterbox.isReady())
        }
    }

    func start() {
        shouldContinue = true
        status = ""
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                    Task { @MainActor in
                        guard let self else { return }
                        allowed ? await self.beginListening() : self.cannotListen()
                    }
                }
            } else {
                cannotListen()
            }
            return
        }
        Task { await beginListening() }
    }

    func stop() {
        shouldContinue = false
        timer?.invalidate(); timer = nil
        if let session { _ = audio.end(session) }
        session = nil
        player?.stop(); player = nil
        phase = .idle
        status = ""
    }

    private func cannotListen() {
        shouldContinue = false
        phase = .unavailable
        status = "Allow microphone access to talk with your Brain."
    }

    private func beginListening() async {
        guard shouldContinue else { return }
        if !TranscriptionService.shared.isReady {
            phase = .preparing
            await TranscriptionService.shared.load(kind: TranscriptionService.shared.dictationKind)
        }
        guard shouldContinue else { return }
        let othersOnMic = await AudioCapture.processesUsingMicOffMain()
            .contains { $0 != Bundle.main.bundleIdentifier }
        let started: UUID
        do {
            started = try await audio.begin(othersOnMic ? .raw : .voiceProcessed)
        } catch {
            phase = .unavailable
            status = "My Man couldn't start the microphone."
            shouldContinue = false
            return
        }
        // Starting the device blocks on CoreAudio — stop() may have run while
        // we waited, and a listening session nobody owns records forever.
        guard shouldContinue else {
            _ = audio.end(started)
            return
        }
        session = started
        phase = .listening
        status = "Listening… pause when you're done."
        heardSpeech = false; silenceSince = nil; peak = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLevel() }
        }
    }

    private func pollLevel() {
        guard case .listening = phase, let session else { return }
        let level = audio.currentLevel(for: session)
        peak = max(peak, level)
        var next = levels; next.removeFirst(); next.append(min(1, level / max(peak, 0.006))); levels = next
        if level > threshold {
            heardSpeech = true; silenceSince = nil
        } else if heardSpeech {
            if let silenceSince, Date().timeIntervalSince(silenceSince) >= 1.15 {
                finishListening()
            } else if silenceSince == nil {
                self.silenceSince = Date()
            }
        }
    }

    private func finishListening() {
        timer?.invalidate(); timer = nil
        let samples = session.map { audio.end($0) } ?? []
        session = nil
        guard samples.count > 4_800 else { // ignore accidental taps
            Task { await beginListening() }
            return
        }
        phase = .transcribing
        status = "Turning that into text…"
        Task { @MainActor in
            let raw = await TranscriptionService.shared.transcribe(samples)
            let text = await DictationCleanup.clean(raw, tone: SettingsStore.shared.dictationTone, targetBundleID: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if shouldContinue { await beginListening() }
                return
            }
            status = ""
            onTranscript?(text)
        }
    }

    func speak(_ text: String) {
        pendingSpeech = text
        phase = .speaking
        status = "Chatterbox is replying…"
        Task { @MainActor in
            do {
                let audioData = try await Chatterbox.synthesize(text)
                guard shouldContinue else { return }
                let player = try AVAudioPlayer(data: audioData)
                self.player = player
                player.delegate = self
                player.prepareToPlay()
                player.play()
                self.pendingSpeech = ""
                self.needsVoiceSetup = false
                status = ""
            } catch {
                phase = .unavailable
                needsVoiceSetup = true
                status = "Install local voice replies to hear answers."
            }
        }
    }

    func installVoiceReplies() {
        guard !isInstallingVoice else { return }
        isInstallingVoice = true
        status = "Installing local voice replies…"
        Task { @MainActor in
            do {
                try await Chatterbox.installAndStart()
                isInstallingVoice = false
                needsVoiceSetup = false
                status = "Voice replies are ready."
                phase = .idle
                if !pendingSpeech.isEmpty { speak(pendingSpeech) }
            } catch {
                isInstallingVoice = false
                needsVoiceSetup = true
                status = "Couldn’t install voice replies. Please try again."
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player = nil
            if self.shouldContinue { await self.beginListening() }
            else { self.phase = .idle }
        }
    }
}

/// Ephemeral conversation over the local Brain. Messages remain only in this
/// panel's memory: no SQLite rows, markdown files, analytics, or clipboard.
@MainActor
final class BrainChatController {
    static let shared = BrainChatController()
    private var panel: FloatingPanel?

    func show(scope: BrainChatScope = .init()) {
        let view = BrainChatView(initialScope: scope) { [weak self] in self?.panel?.dismiss() }
        panel?.dismiss()
        panel = FloatingPanel(content: view, fixedSize: true)
        panel?.setContentSize(NSSize(width: 620, height: 720))
        panel?.dismissesOnResign = false
        panel?.onDismiss = { [weak self] in self?.panel = nil }
        panel?.present()
    }
}

private struct BrainChatMessage: Identifiable {
    enum Role { case user, brain }
    let id = UUID()
    let role: Role
    let text: String
    var answer: BrainChatAnswer? = nil
}

struct BrainChatView: View {
    var initialScope: BrainChatScope
    let onDismiss: () -> Void
    @State private var scope = BrainChatScope()
    @State private var themes: [CaptureTheme] = []
    @State private var dateFilter = false
    @State private var after = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var before = Date()
    @State private var selectedSource: BrainChatSource?
    @State private var recipes = BrainChatRecipe.saved
    @State private var messages: [BrainChatMessage] = []
    @State private var draft = ""
    @State private var isThinking = false
    @StateObject private var voice = BrainChatVoiceController()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconView(icon: .chat, size: 18, color: MM.Colors.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chat with your Brain").font(MM.Fonts.secondary)
                    Text("Cited answers · conversation stays in this window").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
                Spacer()
                Button("Exit") { voice.stop(); onDismiss() }
                    .buttonStyle(.plain).clickable(minSize: 26).font(MM.Fonts.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(MM.Colors.surface))
                    .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
            }
            .padding(MM.Layout.paddingLarge)
            Divider().overlay(MM.Colors.border)
            scopeControls.padding(.horizontal, MM.Layout.paddingLarge).padding(.vertical, MM.Layout.spacing)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in messageBubble(message) }
                    if isThinking { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching your Brain…").font(MM.Fonts.secondary) }.foregroundStyle(MM.Colors.textSecondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(MM.Layout.paddingLarge)
            }.frame(maxHeight: .infinity)
                .overlay {
                    if messages.isEmpty && !isThinking {
                        UtilityEmptyState(icon: .chat, title: "Pick up a thought", message: "Ask about something you've captured.")
                    }
                }

            Divider().overlay(MM.Colors.border)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Ask your Brain…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(MM.Fonts.bodyInput).focused($inputFocused).lineLimit(1...4)
                        .onKeyPress(.return) { send(); return .handled }
                    Button("Send") { send() }.buttonStyle(.plain).clickable(minSize: 26).font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(canSend ? MM.Colors.textPrimary : MM.Colors.textTertiary)).disabled(!canSend)
                }
                HStack(spacing: 8) {
                    Button(voice.phase == .idle || voice.phase == .unavailable ? "Start talking" : "End voice chat") {
                        if voice.phase == .idle || voice.phase == .unavailable { voice.start() } else { voice.stop() }
                    }
                    .buttonStyle(.plain).clickable(minSize: 25).font(MM.Fonts.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(MM.Colors.surface))
                    .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                    if voice.phase == .listening { waveform }
                    if voice.needsVoiceSetup || voice.isInstallingVoice {
                        Button(voice.isInstallingVoice ? "Installing…" : "Install voice replies") {
                            voice.installVoiceReplies()
                        }
                        .buttonStyle(.plain).clickable(minSize: 25).font(MM.Fonts.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                        .disabled(voice.isInstallingVoice)
                    }
                    Text(voice.status.isEmpty ? "Tap once — turns continue automatically." : voice.status)
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).lineLimit(1)
                    Spacer()
                }
            }.padding(MM.Layout.paddingLarge)
        }
        .frame(width: 620, height: 720)
        .background(RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous).fill(MM.Colors.background)
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous).strokeBorder(MM.Colors.border, lineWidth: 1)))
        .onAppear {
            scope = initialScope
            themes = (try? ThemeStore.list()) ?? []
            inputFocused = true
            voice.onTranscript = { text in send(text) }
            voice.checkVoiceReplies()
        }
        .onDisappear { voice.stop() }
        .sheet(item: $selectedSource) { source in
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                Text(source.title).font(MM.Fonts.title)
                Text(source.date.formatted(date: .abbreviated, time: .shortened)).font(MM.Fonts.metadata)
                ScrollView { Text(source.text).font(MM.Fonts.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Open source") {
                        if let item = CaptureIndex.item(source.itemID), !item.excluded { CaptureActions.open(item, query: String(source.text.prefix(100))) }
                    }.clickable()
                    if CaptureIndex.item(source.itemID)?.revision != source.revision { Text("Source changed since this answer.").font(MM.Fonts.metadata) }
                    Spacer()
                    Button("Done") { selectedSource = nil }.clickable()
                }
            }.padding(MM.Layout.paddingLarge).frame(width: 560, height: 420)
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                if scope.itemID != nil {
                    Text("This capture").font(MM.Fonts.secondary)
                    Button("All captures") { scope.itemID = nil }.clickable()
                } else {
                    Picker("Sources", selection: $scope.kind) {
                        Text("All captures").tag("all"); Text("Meetings").tag("meeting"); Text("Notes").tag("note"); Text("Recordings").tag("recording")
                    }.clickable()
                    Picker("Theme", selection: Binding(get: { scope.themeID ?? "" }, set: { scope.themeID = $0.isEmpty ? nil : $0 })) {
                        Text("All themes").tag("")
                        ForEach(themes) { Text($0.title).tag($0.id) }
                    }.clickable()
                }
            }
            HStack {
                TextField("Person or company mentioned", text: $scope.person).clickable()
                Toggle("Date range", isOn: $dateFilter).clickable()
            }
            if dateFilter {
                HStack {
                    DatePicker("From", selection: $after, displayedComponents: .date).clickable()
                    DatePicker("Through", selection: $before, displayedComponents: .date).clickable()
                }
            }
            HStack {
                Menu("Recipes") { ForEach(recipes) { recipe in Button(recipe.name) { draft = recipe.prompt }.clickable() } }.clickable()
                Button("Save question as recipe…") {
                    CaptureActions.prompt(title: "Recipe name", value: "My recipe") { name in
                        BrainChatRecipe.save(name: name, prompt: draft); recipes = BrainChatRecipe.saved
                    }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).clickable()
                Spacer()
            }
        }.font(MM.Fonts.secondary).disabled(isThinking)
    }

    private var waveform: some View {
        HStack(spacing: 2) { ForEach(Array(voice.levels.enumerated()), id: \.offset) { _, level in
            Capsule().fill(MM.Colors.accent).frame(width: 2, height: max(3, CGFloat(level) * 14))
        }}.frame(height: 16)
    }
    private var canSend: Bool { !isThinking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func messageBubble(_ message: BrainChatMessage) -> some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text(message.text).font(MM.Fonts.body).foregroundStyle(MM.Colors.textPrimary).textSelection(.enabled)
            if let answer = message.answer {
                ForEach(answer.citations) { citation in
                    if let source = answer.sources.first(where: { $0.id == citation.sourceID }) {
                        Button("[\(source.id)] \(source.title) · \(source.date.formatted(date: .abbreviated, time: .omitted))") { selectedSource = source }
                            .font(MM.Fonts.secondary).clickable()
                    }
                }
                if !answer.coverage.isEmpty { Text(answer.coverage).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary) }
            }
        }.padding(MM.Layout.spacing).frame(maxWidth: 530, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).fill(message.role == .user ? MM.Colors.surface : MM.Colors.background))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: message.role == .user ? 0 : 1))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
    private func send() { send(draft) }
    private func send(_ source: String) {
        let question = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        var requestedScope = scope
        if dateFilter {
            requestedScope.after = Calendar.current.startOfDay(for: min(after, before))
            requestedScope.before = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(after, before)))
        }
        draft = ""; messages.append(.init(role: .user, text: question)); isThinking = true
        let prior = messages.suffix(6).map { ($0.role == .user ? "User" : "Brain") + ": " + $0.text }
        Task { @MainActor in
            let answer = await BrainChat.respond(question: question, history: prior, scope: requestedScope)
            messages.append(.init(role: .brain, text: answer.text, answer: answer)); isThinking = false; inputFocused = true
            voice.speak(answer.text)
        }
    }
}

enum BrainChat {
    static func answer(question: String, history: [String]) async -> String {
        await respond(question: question, history: history).text
    }

    static func respond(question: String, history: [String], scope: BrainChatScope = .init()) async -> BrainChatAnswer {
        if scope.isAll, BrainCalendar.isTodayScheduleQuestion(question) { return BrainChatAnswer(text: BrainCalendar.todayAnswer()) }
        if scope.isAll, BrainTasks.isOpenTasksQuestion(question) { return BrainChatAnswer(text: BrainTasks.openTasksAnswer()) }
        let retrieval: BrainChatRetrieval
        do { retrieval = try await Task.detached(priority: .userInitiated) { try BrainChatRetrieval.retrieve(question, scope: scope) }.value }
        catch { return BrainChatAnswer(text: "The selected sources could not be read. Please try again.") }
        guard !retrieval.sources.isEmpty else {
            return BrainChatAnswer(text: "I couldn't find a passage that answers this in the selected scope.", coverage: retrieval.coverage)
        }
        let prompt = "Coverage: \(retrieval.coverage)\n<SOURCES>\n\(retrieval.sources.map(\.prompt).joined(separator: "\n\n"))\n</SOURCES>\nRecent conversation (not evidence): \(history.joined(separator: "\n").suffix(2000))\nQuestion: \(question.prefix(4000))"
        if let provider = WritingModels.current(for: .brainChat) {
            if let generated = try? await provider.generate(WritingRequest(instructions: BrainChatAnswer.instructions, input: prompt, jsonSchema: nil, deadline: 30, purpose: .brainChat)),
               let answer = BrainChatAnswer.validated(generated.text, retrieval: retrieval) { return answer }
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            if let generated = try? await AsyncDeadline.run(seconds: 25, operation: {
                try await LanguageModelSession(instructions: BrainChatAnswer.instructions).respond(to: prompt).content
            }), let answer = BrainChatAnswer.validated(generated, retrieval: retrieval) { return answer }
        }
        #endif
        return BrainChatAnswer(text: "I couldn't produce an answer with verified source quotations. These are the relevant passages you can review.",
                               citations: retrieval.sources.prefix(4).map { .init(sourceID: $0.id, quote: $0.text) },
                               sources: retrieval.sources, coverage: retrieval.coverage)
    }
}
