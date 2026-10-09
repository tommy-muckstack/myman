import AppKit
import SwiftUI

/// The Brainz section at the top of the Library page: which folder is
/// indexed, how many notes it found, and which folders stay out.
struct BrainzSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var status = BrainIndexStatus.shared
    @State private var excludedText = SettingsStore.shared.brainExcludedFolders.joined(separator: ", ")

    private var pointerExists: Bool { FileManager.default.fileExists(atPath: BrainWorkspace.pointerURL.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            Text("Brainz notes")
                .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
            HStack(spacing: MM.Layout.spacing / 2) {
                Text(folderLabel)
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Change…") { pickFolder() }
                    .buttonStyle(.plain).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.accent).clickable()
                if pointerExists, store.brainFolderPath != nil {
                    Button("Use Brainz folder") { store.brainFolderPath = nil }
                        .buttonStyle(.plain).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.accent).clickable()
                }
            }
            HStack(spacing: MM.Layout.spacing / 2) {
                Text(statusLine)
                    .font(MM.Fonts.metadata).foregroundStyle(status.lastError == nil ? MM.Colors.textTertiary : MM.Colors.danger)
                if status.isScanning { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button("Rescan") { BrainNoteIndexer.shared.rescan(reason: "settings") }
                    .buttonStyle(.plain).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.accent).clickable()
                    .disabled(status.root == nil)
            }
            TextField("Folders to skip (names, separated by commas)", text: $excludedText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitExcluded() }
                .onChange(of: excludedText) { _, _ in commitExcluded() }
            Text("Notes are read from the folder Brainz has open so meetings can surface related ones. Files are never changed or moved. Search shows them as Brainz notes.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Brainz notes")
    }

    private var folderLabel: String {
        if let root = status.root { return root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if let picked = store.brainFolderPath, !picked.isEmpty {
            return picked.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " (not a Brainz folder)"
        }
        return "No Brainz folder found"
    }

    private var statusLine: String {
        if let error = status.lastError { return "Couldn’t read the folder: \(error)" }
        guard status.root != nil else { return "Pick the folder Brainz has open, or open a brain in Brainz." }
        let notes = status.count == 1 ? "1 note indexed" : "\(status.count) notes indexed"
        if let last = status.lastScan {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return notes + " · " + formatter.localizedString(for: last, relativeTo: Date())
        }
        return notes
    }

    private func commitExcluded() {
        let names = excludedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names != store.brainExcludedFolders { store.brainExcludedFolders = names }
    }

    private func pickFolder() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.allowsMultipleSelection = false
        dialog.prompt = "Use folder"
        dialog.message = "Choose the folder Brainz has open"
        if let root = status.root { dialog.directoryURL = root }
        if dialog.runModal() == .OK, let url = dialog.url {
            store.brainFolderPath = url.path
        }
    }
}
