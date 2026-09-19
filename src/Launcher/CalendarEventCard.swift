import SwiftUI

struct CalendarEventCard: View {
    let event: CalendarPanelView.EventLite
    var onOpen: () -> Void
    var onJoin: () -> Void
    var onBrief: () -> Void
    var onNotes: () -> Void
    @State var hovered = false
    @FocusState private var focused: Action?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Action: Hashable { case event, open, join, brief, notes }
    private var showActions: Bool { hovered || focused != nil || voiceOver }
    private var joinLabel: String {
        let host = event.joinURL?.host?.lowercased() ?? ""
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Join Zoom" }
        if host == "meet.google.com" { return "Join Meet" }
        return "Join call"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if event.hasMeetingLink {
                    Circle().fill(MM.Colors.accent).frame(width: 5, height: 5)
                }
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                Spacer(minLength: 0)
                if event.meetingID != nil {
                    Button(action: onNotes) {
                        Label("Notes", systemImage: "doc.text")
                            .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.accent)
                            .clickable()
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: .notes)
                    .help("Open this meeting’s notes")
                }
            }
            Button(action: onOpen) {
                Text(event.title).font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clickable()
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .event)
            .help("Open calendar event")

            // Reserve the action strip so adjacent events stay still on hover.
            HStack(spacing: 6) {
                action("Open", icon: "arrow.up.right", focus: .open, run: onOpen)
                    .help("Open calendar event")
                if event.joinURL != nil {
                    action(joinLabel, icon: "video", focus: .join, run: onJoin)
                        .help("Join this event’s video call")
                }
                Spacer(minLength: 0)
                action("Brief", icon: "sparkles", focus: .brief, run: onBrief)
                    .help("Prepare meeting brief")
            }
            .allowsHitTesting(showActions)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { content in
                content.opacity(showActions ? 1 : 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
            .strokeBorder(showActions ? MM.Colors.border : .clear, lineWidth: 1)
            .allowsHitTesting(false))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDisappear { hovered = false }
        .accessibilityElement(children: .contain)
    }

    private func action(_ title: String, icon: String, focus: Action, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textPrimary)
                .padding(.horizontal, 6)
                .frame(minHeight: 24)
                .background(MM.Colors.background, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }
        .buttonStyle(.plain)
        .focused($focused, equals: focus)
    }
}
