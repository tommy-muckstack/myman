import SwiftUI
import GRDB

struct MeetingDecisionsView: View {
    @ObservedObject private var store = MeetingDecisions.shared
    @State private var meetings: [CaptureItem] = []
    @State private var sourceID = ""
    @State private var topic = ""
    @State private var statement = ""
    @State private var quote = ""
    @State private var search = ""
    @State private var selected = Set<String>()
    @State private var related = Set<String>()
    @State private var message = ""
    @State private var speakerFrom = ""
    @State private var speakerTo = ""
    private var source: CaptureItem? { meetings.first { $0.id == sourceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Decisions across meetings").font(MM.Fonts.title)
            Text("Keep a dated decision with its exact supporting quote. Records stay in the timeline when wording changes; stale evidence must be reviewed again.").font(MM.Fonts.secondary)
            DisclosureGroup("Add a decision or correct a speaker") {
                VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                    Picker("Meeting", selection: $sourceID) { Text("Choose a meeting").tag(""); ForEach(meetings) { Text($0.title).tag($0.id) } }.clickable()
                    if let source {
                        Button("Read source transcript") { CaptureDetailController.shared.open(source) }.clickable()
                        TextField("Topic, e.g. Checkout launch", text: $topic).textFieldStyle(.roundedBorder)
                        TextField("Decision to remember", text: $statement).textFieldStyle(.roundedBorder)
                        Text("Paste the exact supporting quote from one transcript turn.").font(MM.Fonts.secondary)
                        TextEditor(text: $quote).font(MM.Fonts.body).frame(height: 100).accessibilityLabel("Supporting transcript quote")
                        Button("Save reviewed decision") { attempt { _ = try store.add(sourceID: source.id, revision: source.revision, topic: topic, text: statement, quote: quote, human: true); topic = ""; statement = ""; quote = "" } }.clickable()
                        HStack { TextField("Current speaker label", text: $speakerFrom); TextField("Correct speaker name", text: $speakerTo) }.textFieldStyle(.roundedBorder)
                        Button("Correct this speaker in the transcript") { attempt { try correctSpeaker(source) } }.clickable()
                    }
                }.padding(.vertical, MM.Layout.spacing)
            }.clickable()
            TextField("Filter decision topics", text: $search).textFieldStyle(.roundedBorder)
            ForEach(store.decisions.filter { search.isEmpty || ($0.topic + " " + $0.text).localizedCaseInsensitiveContains(search) }.sorted { $0.capturedAt > $1.capturedAt }) { value in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { selected.contains(value.id) }, set: { if $0 { selected.insert(value.id) } else { selected.remove(value.id) } })) {
                        Text(value.topic).font(MM.Fonts.body)
                    }.clickable().disabled(!value.confirmed || !store.current(value))
                    Text(value.text)
                    Text("\(value.capturedAt.formatted()) · \(value.speaker) · \(value.timestamp.isEmpty ? "timing unavailable" : value.timestamp)").font(MM.Fonts.metadata)
                    Text(value.quote).font(MM.Fonts.secondary).textSelection(.enabled)
                    HStack {
                        if let item = CaptureIndex.item(value.sourceID) { Button("Inspect evidence") { CaptureDetailController.shared.open(item, query: value.quote) }.clickable() }
                        if !store.current(value) { Text("Source changed — create a fresh record.").foregroundStyle(MM.Colors.danger) }
                        else if !value.confirmed { Button("Confirm after review") { attempt { try store.confirm(value.id) } }.clickable() }
                        Button("Remove record") { attempt { try store.remove(value.id); selected.remove(value.id) } }.clickable()
                    }
                }.padding(MM.Layout.spacing).background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            }
            if let source {
                DisclosureGroup("Choose related screenshots and notes for the follow-up") {
                    ForEach((try? RelatedItems.items(for: source.id)) ?? []) { relationship in
                        let item = relationship.item
                        Toggle(item.title, isOn: Binding(get: { related.contains(item.id) }, set: { if $0 { related.insert(item.id) } else { related.remove(item.id) } })).clickable()
                    }
                }.clickable()
            }
            Button("Create follow-up draft from selected decisions") {
                attempt { let markdown = try store.followup(ids: Array(selected), relatedIDs: Array(related)); NoteDocumentController.shared.create(body: markdown) }
            }.disabled(selected.isEmpty).clickable()
            Text(message).font(MM.Fonts.secondary)
        }.onAppear { refresh() }
    }
    private func refresh() { meetings = (try? CaptureIndex.history(filter: CaptureFilter(kind: "meeting"), limit: 200)) ?? [] }
    private func attempt(_ action: () throws -> Void) { do { try action(); message = "Saved." } catch { message = error.localizedDescription } }
    private func correctSpeaker(_ source: CaptureItem) throws {
        _ = try MeetingDecisions.correctSpeaker(source: source, from: speakerFrom, to: speakerTo)
        refresh()
        Toast.show("Speaker updated. Review existing meeting notes for references to the old name.")
    }
}
