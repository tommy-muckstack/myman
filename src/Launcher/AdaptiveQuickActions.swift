import AppKit
import SwiftUI

/// The same shortcuts and recent captures as the classic launcher, below the input.
struct AdaptiveQuickActions: View {
    let actions: [LauncherAction]
    var libraryModel: CaptureLibraryModel?
    let onDismiss: () -> Void
    let onSaveQueryAsNote: (String) -> Void
    @StateObject private var filters = CaptureLibraryFilters()
    @State private var hovered: String?
    @State private var insideRecents = false
    @State private var showHints = true
    @State private var openingMouse = NSEvent.mouseLocation

    private var shouldDismiss: Bool { filters.actionKind != nil && hovered == nil && !insideRecents }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    Button { onDismiss(); action.run() } label: {
                        LauncherActionChip(action: action, selected: hovered == action.id,
                                           hintVisible: showHints || hovered == action.id)
                    }.buttonStyle(.plain).disabled(!action.enabled).accessibilityLabel(action.title)
                        .clickable(enabled: action.enabled)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                let mouse = NSEvent.mouseLocation
                                guard hypot(mouse.x - openingMouse.x, mouse.y - openingMouse.y) > 2 else { return }
                                hovered = action.enabled ? action.id : nil
                                filters.actionKind = action.enabled ? action.captureKind : nil
                            case .ended:
                                if hovered == action.id { hovered = nil }
                            }
                        }
                }
            }.padding(8)
            if filters.actionKind != nil {
                CaptureLibraryView(query: .constant(""), mode: .constant(.search), controls: filters,
                                   onDismiss: onDismiss, onSaveQueryAsNote: onSaveQueryAsNote, model: libraryModel)
                    .onHover { insideRecents = $0 }
                    .onDisappear { insideRecents = false }
            }
        }
        .onAppear { openingMouse = NSEvent.mouseLocation }
        .task { try? await Task.sleep(for: .seconds(2.3)); if !Task.isCancelled { showHints = false } }
        .task(id: shouldDismiss) {
            guard shouldDismiss else { return }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            if shouldDismiss { filters.actionKind = nil }
        }
        .onHover { if !$0 { hovered = nil; filters.actionKind = nil; insideRecents = false } }
    }
}
