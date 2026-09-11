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
