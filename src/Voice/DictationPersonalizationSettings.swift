import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DictationPersonalizationSettings: View {
    @ObservedObject private var store = DictationPersonalizationStore.shared
    @State private var draft = DictationPersonalization()
    @State private var message = ""
    @AppStorage("dictationContextEnabled") private var contextEnabled = false
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Button("Snippets, dictionary aliases and voice transforms…") {
                draft = store.value; showingEditor = true
            }.clickable()
            Toggle("Use nearby text to recognize names", isOn: $contextEnabled).clickable()
            Text("Reads the focused text field only while you dictate. Context stays in memory on this Mac; secure fields are excluded.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            DictationProfileSettings()
        }.sheet(isPresented: $showingEditor) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: MM.Layout.padding) {
            Text("Your words, exactly").font(MM.Fonts.title)
            ScrollView {
                VStack(alignment: .leading, spacing: MM.Layout.padding) {
                    Text("Snippets").font(MM.Fonts.body)
                    Text("Say a cue to insert its expansion verbatim. Longer matching cues win.").font(MM.Fonts.metadata)
                    ForEach($draft.snippets) { $snippet in
                        VStack(alignment: .leading) {
                            HStack {
                                TextField("Spoken cue", text: $snippet.cue).clickable()
                                Button("Remove") { draft.snippets.removeAll { $0.id == snippet.id } }.clickable()
                            }
                            TextEditor(text: $snippet.expansion).font(MM.Fonts.secondary).frame(height: 70)
                                .accessibilityLabel("Exact snippet expansion")
                        }
                    }
                    Button("Add snippet") { draft.snippets.append(.init(cue: "", expansion: "")) }.clickable()
                    Divider()
                    Text("Dictionary aliases").font(MM.Fonts.body)
                    ForEach($draft.aliases) { $alias in
                        HStack {
                            TextField("Correct spelling", text: $alias.term).clickable()
                            TextField("Misheard forms, separated by commas", text: Binding(
                                get: { alias.soundsLike.joined(separator: ", ") },
                                set: { alias.soundsLike = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                            )).clickable()
                            Button("Remove") { draft.aliases.removeAll { $0.id == alias.id } }.clickable()
                        }
                    }
                    Button("Add alias") { draft.aliases.append(.init(term: "", soundsLike: [])) }.clickable()
                    Divider()
                    Text("Voice transforms").font(MM.Fonts.body)
                    Text("Select text, press the Voice Edit shortcut, and say a transform name or your own instruction. Press the shortcut again to finish.")
                        .font(MM.Fonts.metadata)
                    ForEach($draft.transforms) { $transform in
                        HStack {
                            TextField("Name", text: $transform.name).frame(width: 110).clickable()
                            TextField("Instruction", text: $transform.instruction).clickable()
                            Button("Remove") { draft.transforms.removeAll { $0.id == transform.id } }.clickable()
                        }
                    }
                    Button("Add transform") { draft.transforms.append(.init(name: "", instruction: "")) }.clickable()
                }
            }
            if let error = store.loadError { Text(error).font(MM.Fonts.metadata) }
            if !message.isEmpty { Text(message).font(MM.Fonts.metadata).accessibilityLabel(message) }
            HStack {
                Button("Import JSON…", action: importJSON).clickable()
                Button("Export JSON…", action: exportJSON).clickable()
                Spacer()
                Button("Cancel") { showingEditor = false }.clickable()
                Button("Save") {
                    do { try store.save(draft); message = ""; showingEditor = false }
                    catch { message = error.localizedDescription }
                }.clickable().keyboardShortcut(.defaultAction)
            }
        }.font(MM.Fonts.secondary).padding(MM.Layout.paddingLarge).frame(width: 640, height: 600)
    }

    private func importJSON() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try DictationPersonalizationStore.decode(Data(contentsOf: url))
            var next = draft
            for snippet in imported.snippets where !next.snippets.contains(where: { $0.cue.caseInsensitiveCompare(snippet.cue) == .orderedSame }) {
                next.snippets.append(.init(cue: snippet.cue, expansion: snippet.expansion))
            }
            for alias in imported.aliases where !next.aliases.contains(where: { $0.term.caseInsensitiveCompare(alias.term) == .orderedSame }) {
                next.aliases.append(.init(term: alias.term, soundsLike: alias.soundsLike))
            }
            for transform in imported.transforms where !next.transforms.contains(where: { $0.name.caseInsensitiveCompare(transform.name) == .orderedSame }) {
                next.transforms.append(.init(name: transform.name, instruction: transform.instruction))
            }
            draft = try next.validated(); message = "Imported into this draft. Existing entries were kept. Save to apply."
        } catch { message = error.localizedDescription }
    }
    private func exportJSON() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "my-man-personalization.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(draft.validated()).write(to: url, options: .atomic)
            message = "Exported."
        } catch { message = error.localizedDescription }
    }
}
