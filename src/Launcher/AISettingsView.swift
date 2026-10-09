import SwiftUI

/// Settings → AI: the opt-in hosted writing model. The API key goes straight
/// from the SecureField into the Keychain; this view never keeps it in state
/// after saving and nothing here reaches analytics beyond vendor and model.
struct AISettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var keyField = ""
    @State private var hasKey = false
    @State private var keyMessage = ""
    @State private var testing = false
    @State private var testResult = ""

    private var vendor: WritingVendor { store.writingModelVendor }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Better writing, your key.").font(MM.Fonts.title)
            Text("All AI runs on this Mac by default. Optionally send the final meeting notes, task extraction and Brain chat to a hosted model using your own API key.")
                .foregroundStyle(MM.Colors.textSecondary)
            Toggle("Use a hosted model for writing", isOn: $store.writingModelEnabled)
                .toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).clickable()
            Picker("Provider", selection: $store.writingModelVendor) {
                ForEach(WritingVendor.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
            .onChange(of: store.writingModelVendor) { _, _ in refreshKeyState() }
            Text("When on, meeting transcripts, note text and Brain chat context are sent to \(vendor.providerName)'s API with your own key. Nothing is sent while this is off. Live notes during a meeting always stay on-device.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(vendor.label) API key").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
                HStack(spacing: 8) {
                    SecureField("Paste your \(vendor.providerName) API key", text: $keyField)
                        .textFieldStyle(.roundedBorder).font(MM.Fonts.bodyInput)
                    Button("Save to Keychain") { saveKey() }.clickable()
                        .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey { Button("Remove key") { removeKey() }.clickable() }
                }
                Text(statusLine).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                if !keyMessage.isEmpty {
                    Text(keyMessage).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
                if vendor == .claude {
                    Link("Max subscribers get monthly API credits: claude.ai → Settings → Billing → link a Console org, then create a key.",
                         destination: URL(string: "https://claude.ai/settings/billing")!)
                        .font(MM.Fonts.metadata).clickable()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
                HStack(spacing: 8) {
                    TextField(vendor.defaultModel, text: $store.writingModelName)
                        .textFieldStyle(.roundedBorder).font(MM.Fonts.bodyInput).frame(maxWidth: 240)
                    Button(testing ? "Testing…" : "Test") { runTest() }.clickable().disabled(testing || !hasKey)
                }
                if !testResult.isEmpty {
                    Text(testResult).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary).textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Use it for").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
                Toggle("Final meeting notes and follow-ups", isOn: $store.writingModelMeetingNotes)
                    .toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).clickable()
                Toggle("Tasks from notes and dictation", isOn: $store.writingModelTasks)
                    .toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).clickable()
                Toggle("Chat with your Brain", isOn: $store.writingModelBrainChat)
                    .toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).clickable()
            }.disabled(!store.writingModelEnabled)

            Text("The key is stored only in this Mac's Keychain. It is never written to the app's files, logs or analytics. Dictation cleanup, scheduling, Themes, the launcher and text-selection actions always stay on-device.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge)
        .onAppear { refreshKeyState() }
    }

    private var statusLine: String {
        guard hasKey else { return "No key saved for \(vendor.label)." }
        let last = store.writingModelLastTest
        return last.isEmpty ? "Key saved" : "Key saved · last test \(last)"
    }

    private func refreshKeyState() {
        hasKey = Keychain.read(service: vendor.keychainService, account: WritingVendor.keychainAccount) != nil
        keyField = ""
        keyMessage = ""
        testResult = ""
    }

    private func saveKey() {
        let value = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try Keychain.save(value, service: vendor.keychainService, account: WritingVendor.keychainAccount)
            keyField = ""
            hasKey = true
            keyMessage = "Saved to Keychain."
            store.writingModelLastTest = ""
        } catch {
            keyMessage = "Couldn’t save to the Keychain."
        }
    }

    private func removeKey() {
        Keychain.delete(service: vendor.keychainService, account: WritingVendor.keychainAccount)
        hasKey = false
        keyMessage = "Key removed."
        store.writingModelLastTest = ""
        testResult = ""
    }

    private func runTest() {
        let settings = WritingModelSettings(enabled: true, vendor: vendor, model: store.writingModelName)
        guard let provider = WritingModels.current(for: .brainChat, settings: settings) else {
            testResult = WritingModelError.notConfigured.userMessage; return
        }
        testing = true
        testResult = "Contacting \(vendor.providerName)…"
        Task { @MainActor in
            defer { testing = false }
            do {
                let probe: (seconds: Double, model: String)
                if let claude = provider as? ClaudeWritingModel { probe = try await claude.probe() }
                else if let openai = provider as? OpenAIWritingModel { probe = try await openai.probe() }
                else { probe = (0, provider.id) }
                let line = String(format: "OK %.1f s · %@", probe.seconds, probe.model)
                testResult = line
                store.writingModelLastTest = line
                Analytics.track("hosted_writing_tested", ["vendor": vendor.rawValue, "ok": true])
            } catch let error as WritingModelError {
                testResult = error.userMessage
                store.writingModelLastTest = "failed (\(error.reason))"
                Analytics.track("hosted_writing_tested", ["vendor": vendor.rawValue, "ok": false, "reason": error.reason])
            } catch {
                testResult = "The test could not complete."
                store.writingModelLastTest = "failed"
            }
        }
    }
}
