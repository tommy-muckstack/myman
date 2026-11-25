import AppKit

/// Saves a finished recording into a folder you choose inside Google Drive for Desktop. Drive syncs it
/// from there. MyMan makes no Google connection and no upload of its own. To share it, right-click the file
/// in Drive and choose Share, because Drive links can only be made in Drive.
@MainActor enum RecordingDriveFolder {
    static let folderKey = "recordingDriveFolderPath"

    /// The saved folder, if one was picked and still exists.
    static func folder(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: folderKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Asks once for the folder, then remembers it.
    static func chooseFolder(defaults: UserDefaults = .standard) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder in Google Drive"
        panel.message = "Pick a folder inside Google Drive for Desktop. Recordings saved here sync to Drive."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        defaults.set(url.path, forKey: folderKey)
        return url
    }

    /// Copies the recording into the Drive folder and reveals it in Finder.
    static func save(recordingID: String) {
        guard let recording = try? Database.shared.read({ try ScreenRecording.fetchOne($0, key: recordingID) }) else {
            Toast.show("That recording is no longer in the library.", systemImage: "exclamationmark.triangle")
            return
        }
        let movie = URL(fileURLWithPath: recording.path)
        let shareable = ShareReadyMovie.shareURL(for: movie)
        let source = FileManager.default.fileExists(atPath: shareable.path) ? shareable : movie
        guard FileManager.default.fileExists(atPath: source.path) else {
            Toast.show("The recording file is missing.", systemImage: "exclamationmark.triangle")
            return
        }
        guard let folder = folder() ?? chooseFolder() else { return }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            Toast.show("Couldn't save to the Drive folder: \(error.localizedDescription)",
                       systemImage: "exclamationmark.triangle", duration: 12)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        Toast.show("Saved to your Drive folder. Right-click it in Drive to share.", duration: 10)
    }

    /// The most recent saved recording, for the menu bar item.
    static func saveLatest() {
        guard let latest = try? CaptureIndex.history(filter: CaptureFilter(kind: "recording"), limit: 1).first else {
            Toast.show("No recordings yet.", systemImage: "video.slash")
            return
        }
        save(recordingID: String(latest.id.dropFirst("recording-".count)))
    }
}
