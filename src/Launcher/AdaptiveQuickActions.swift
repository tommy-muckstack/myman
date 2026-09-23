import AppKit
import SwiftUI

/// The same shortcuts and recent captures as the classic launcher, below the input.
struct AdaptiveQuickActions: View {
    let actions: [LauncherAction]
    var libraryModel: CaptureLibraryModel?
    let onDismiss: () -> Void
    let onSaveQueryAsNote: (String) -> Void
    var onSelectTool: (String) -> Void = { _ in }
    @StateObject private var filters = CaptureLibraryFilters()
    @State private var hovered: String?
    @State private var insideRecents = false
    @State private var showingTools = false
    @State private var showHints = true
    @State private var openingMouse = NSEvent.mouseLocation

    private var shouldDismiss: Bool { (filters.actionKind != nil || showingTools) && hovered == nil && !insideRecents }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    Button {
                        if action.id == "quick_tools" {
                            showingTools = true; filters.actionKind = nil; hovered = action.id
                        } else { onDismiss(); action.run() }
                    } label: {
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
                                showingTools = action.enabled && action.id == "quick_tools"
                                filters.actionKind = action.enabled ? action.captureKind : nil
                            case .ended:
                                if hovered == action.id { hovered = nil }
                            }
                        }
                }
            }.padding(8)
            if showingTools {
                Divider().overlay(MM.Colors.border)
                AdaptiveResultScroll { QuickToolMenu(onSelect: onSelectTool) }
                    .onHover { insideRecents = $0 }
                    .onDisappear { insideRecents = false }
            } else if filters.actionKind != nil {
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
            if shouldDismiss { filters.actionKind = nil; showingTools = false }
        }
        .onHover { if !$0 { hovered = nil; filters.actionKind = nil; showingTools = false; insideRecents = false } }
    }
}

struct QuickToolShortcut: Identifiable {
    let id: String
    let title: String
    let icon: MMIcon
    let query: String
    static let all: [Self] = [
        .init(id: "calculator", title: "Calculator", icon: .calculator, query: "calculator"),
        .init(id: "timer", title: "Timer", icon: .timer, query: "timer "),
        .init(id: "reminder", title: "Reminder", icon: .reminder, query: "reminder "),
        .init(id: "converter", title: "Unit converter", icon: .calculator, query: "convert "),
        .init(id: "timezones", title: "Time zones", icon: .calendar, query: "time zones"),
        .init(id: "color", title: "Color palette", icon: .themes, query: "color "),
        .init(id: "split", title: "Split a bill", icon: .calculator, query: "split "),
        .init(id: "checklist", title: "Checklist", icon: .checklistUnchecked, query: "checklist ")
    ]
}

struct QuickToolMenu: View {
    let onSelect: (String) -> Void
    @State private var hovered: String?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(QuickToolShortcut.all) { tool in
                Button { onSelect(tool.query) } label: {
                    HStack(spacing: MM.Layout.spacing) {
                        IconView(icon: tool.icon, color: MM.Colors.textSecondary)
                        Text(tool.title).font(MM.Fonts.body)
                        Spacer()
                    }.padding(.horizontal, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing / 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hovered == tool.id ? MM.Colors.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                        .clickable()
                }.buttonStyle(.plain).accessibilityLabel("Open \(tool.title)")
                    .onHover { hovered = $0 ? tool.id : nil }
            }
        }.padding(MM.Layout.spacing)
    }
}
