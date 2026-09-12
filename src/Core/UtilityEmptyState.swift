import SwiftUI

/// One quiet, reusable empty-state treatment for utility panels and documents.
struct UtilityEmptyState: View {
    let icon: MMIcon
    let title: String
    let message: String
    var actionTitle: String? = nil
    var compact = false
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            IconView(icon: icon, size: compact ? 24 : 32, color: MM.Colors.accent)
                .frame(width: compact ? 48 : 68, height: compact ? 48 : 68)
                .background(RoundedRectangle(cornerRadius: compact ? 14 : 19).fill(MM.Colors.accent.opacity(0.10)))
                .rotationEffect(.degrees(-7))
                .accessibilityHidden(true)
                .padding(.bottom, compact ? 14 : 22)
            Text(title)
                .font(MM.Fonts.body).foregroundStyle(MM.Colors.textPrimary)
                .padding(.bottom, 7)
            Text(message)
                .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
                        .padding(.horizontal, 17).padding(.vertical, 9)
                        .background(Capsule().fill(MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                }.buttonStyle(.plain).clickable().padding(.top, 22)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .padding(compact ? 16 : 24)
    }
}
