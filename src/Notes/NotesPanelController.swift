import AppKit
import SwiftUI

@MainActor
final class NotesPanelController {
    private let store = NotesStore()
    private var panel: FloatingPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.dismiss()
        } else {
            show()
        }
    }

    func show(editing note: Note? = nil) {
        // Rebuilt per show so an initial editing target can be injected.
        let view = CapturePanelView(store: store, initialEditing: note, onDismiss: { [weak self] in
            self?.panel?.dismiss()
        })
        panel?.dismiss()
        panel = FloatingPanel(content: view)
        // A half-typed note survives trips to other windows to copy links —
        // Esc / ⏎-save / ✕ are the deliberate ways out.
        panel?.dismissesOnResign = false
        panel?.present()
    }
}
