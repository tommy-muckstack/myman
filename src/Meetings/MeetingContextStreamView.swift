import SwiftUI

/// The "From your past" feed under the Notes editor while recording. Three
/// cards show; the rest wait behind "N more". Nothing moves: cards fade in
/// and out so the editor above stays calm.
struct MeetingContextStreamView: View {
    @ObservedObject var stream: MeetingContextStream
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if stream.enabled, !stream.hiddenForMeeting, !stream.cards.isEmpty {
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                HStack(spacing: MM.Layout.spacing / 2) {
                    Text("From your past")
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textSecondary)
                    if stream.isRefreshing { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                    Button("Hide for this meeting") { stream.hideForMeeting() }
                        .buttonStyle(.plain)
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textTertiary)
                        .clickable(minSize: 20)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleCards) { card in
                            MeetingContextCardView(card: card, open: { stream.open(card) }, dismiss: { stream.dismiss(card) })
                                .transition(.opacity)
                        }
                        if stream.cards.count > MeetingContextStream.visibleCount {
                            Button(expanded ? "Show less" : "\(stream.cards.count - MeetingContextStream.visibleCount) more") {
                                expanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(MM.Fonts.metadata)
                            .foregroundStyle(MM.Colors.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clickable(minSize: 20)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: stream.cards.map(\.id))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Related past context")
        }
    }

    private var visibleCards: [MeetingContextCard] {
        expanded ? stream.cards : Array(stream.cards.prefix(MeetingContextStream.visibleCount))
    }
}

struct MeetingContextCardView: View {
    let card: MeetingContextCard
    var open: () -> Void
    var dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(icon: card.item.icon, size: 14, color: MM.Colors.textSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.item.title)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .lineLimit(1)
                Text(card.reason)
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textTertiary)
                    .lineLimit(1)
                if !card.excerpt.isEmpty {
                    Text(card.excerpt)
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                IconView(icon: .close, size: 10, color: MM.Colors.textTertiary)
                    .clickable(minSize: 20)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
        .clickable()
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Dismiss", action: dismiss)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.item.kindLabel): \(card.item.title). \(card.reason)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}
