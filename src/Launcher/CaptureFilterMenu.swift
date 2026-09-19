import SwiftUI

@MainActor final class CaptureLibraryFilters: ObservableObject {
    @Published var kind = "all"
    /// Hover browsing stays selected while moving into the results, but does
    /// not replace the user's explicit content filter when search starts.
    @Published var actionKind: String?
    @Published var isBrowsing = false
    // A capture shortcut must not silently narrow an open theme. Explicit
    // content filters remain available through the filter menu.
    var displayedKind: String { themeID.isEmpty ? (actionKind ?? kind) : kind }
    @Published var period = "any"
    @Published var themeID = ""
    @Published var pinned = false
    @Published var includeExcluded = false
    @Published var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var customEnd = Date()
    func reset() { actionKind = nil; isBrowsing = false; kind = "all"; period = "any"; themeID = ""; pinned = false; includeExcluded = false }
    func showTheme(_ id: String) { reset(); themeID = id; isBrowsing = true }
    var active: Bool { displayedKind != "all" || period != "any" || !themeID.isEmpty || pinned || includeExcluded }
}

struct CaptureFilterMenu: View {
    @Binding var mode: CaptureLibraryMode
    @ObservedObject var filters: CaptureLibraryFilters
    var body: some View {
        Menu {
            Button { filters.reset(); filters.isBrowsing = true; mode = .search } label: { Label("All captures", systemImage: mode == .search && !filters.active ? "checkmark" : "square.grid.2x2") }
            Button { filters.reset(); mode = .themes } label: { Label { Text("Themes") } icon: { Image(nsImage: MMIcon.themes.menuImage) } }
            Divider()
            Menu("Content") {
                ForEach([("all", "All types"), ("screenshot", "Screenshots"), ("meeting", "Meetings"), ("dictation", "Dictation"), ("recording", "Recordings"), ("note", "Notes")], id: \.0) { kind, label in
                    Button { filters.actionKind = nil; filters.kind = kind; filters.isBrowsing = true; mode = .search } label: { Label(label, systemImage: filters.displayedKind == kind ? "checkmark" : "circle") }
                }
            }
            Picker("Date", selection: $filters.period) {
                Text("Any time").tag("any"); Text("Today").tag("today")
                Text("Last 7 days").tag("week"); Text("Last 30 days").tag("month"); Text("Date range…").tag("custom")
            }.disabled(mode == .themes)
            Toggle("Pinned only", isOn: $filters.pinned).disabled(mode == .themes)
            Toggle("Include hidden captures", isOn: $filters.includeExcluded).disabled(mode == .themes)
            if filters.active || mode == .themes {
                Divider()
                Button("Clear filters") { filters.reset(); mode = .search }
            }
        } label: {
            Label { Text("Filters") } icon: { Image(nsImage: MMIcon.filter.menuImage) }
                .labelStyle(.iconOnly)
                .foregroundStyle(filters.active || mode == .themes ? MM.Colors.accent : MM.Colors.textTertiary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .clickable(minSize: 28)
        .help("Filter captures or browse Themes")
        .accessibilityLabel("Filter captures")
        .accessibilityValue(mode == .themes ? "Themes" : filters.active ? "Filters applied" : "All captures")
    }
}
