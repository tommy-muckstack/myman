import SwiftUI

/// Small corrections live with the existing vocabulary settings. Nothing is
/// accepted automatically, and hidden people can be shown again here.
struct MeetingVocabularyControls: View {
    let suggestions: [String]
    let people: [Person]
    var accept: (String) -> Void
    var dismiss: (String) -> Void
    var togglePerson: (Person) -> Void
    @State var peopleExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            if !suggestions.isEmpty {
                Text("Names and terms from your meetings").font(MM.Fonts.secondary)
                ForEach(suggestions, id: \.self) { term in
                    HStack {
                        Text(term).font(MM.Fonts.secondary)
                        Spacer()
                        Button("Add") { accept(term) }
                            .buttonStyle(.plain).foregroundStyle(MM.Colors.accent).clickable()
                        Button("Dismiss") { dismiss(term) }
                            .buttonStyle(.plain).foregroundStyle(MM.Colors.textSecondary).clickable()
                    }
                }
            }
            DisclosureGroup("People from meetings", isExpanded: $peopleExpanded) {
                ForEach(people) { person in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(person.name).font(MM.Fonts.secondary)
                            if let email = person.email, email != person.name {
                                Text(email).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                            }
                        }
                        Spacer()
                        Button(person.hidden ? "Show" : "Hide") { togglePerson(person) }
                            .buttonStyle(.plain).clickable()
                    }.padding(.vertical, MM.Layout.spacing / 2)
                }
            }.font(MM.Fonts.secondary)
        }
    }
}

struct MeetingPeopleFoldersSettings: View {
    @State private var domain = ""
    @State private var folders = UserDefaults.standard.dictionary(forKey: "meetingPeopleFolders") as? [String: String] ?? [:]
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            Text("Company context for meeting names").font(MM.Fonts.secondary)
            HStack {
                TextField("Participant email domain", text: $domain).font(MM.Fonts.secondary)
                Button("Choose folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        folders[domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = url.path
                        UserDefaults.standard.set(folders, forKey: "meetingPeopleFolders")
                        domain = ""
                    }
                }.clickable().disabled(!domain.contains(".") || domain.contains("@") || domain.contains("/"))
            }
            ForEach(folders.keys.sorted(), id: \.self) { domain in
                HStack {
                    Text(domain + " · " + URL(fileURLWithPath: folders[domain]!).lastPathComponent).font(MM.Fonts.metadata)
                        .help(folders[domain]!)
                    Spacer()
                    Button("Remove") {
                        folders.removeValue(forKey: domain)
                        UserDefaults.standard.set(folders, forKey: "meetingPeopleFolders")
                    }.buttonStyle(.plain).font(MM.Fonts.metadata).clickable()
                }
            }
            Text("Company context supplies names, product spellings, and acronyms. Products and acronyms only repair uncertain recognition; common words are never globally boosted.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
        }
    }
}
