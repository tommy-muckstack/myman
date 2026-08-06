import AppKit
import SwiftUI

/// Full-width bar that drains over `duration` — the visual countdown for any
/// auto-dismissing surface (voice result card, toasts).
struct CountdownBar: View {
    let duration: TimeInterval
    var color: Color = .white.opacity(0.35)
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(color)
                .frame(width: max(0, geo.size.width * progress), height: 2)
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.linear(duration: duration)) { progress = 0 }
        }
    }
}

/// Transient toast in the top-right (where the recording pill lives) —
/// for outcomes that deserve a glance, not a modal.
@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String,
                     systemImage: String = "checkmark.circle.fill",
                     actionLabel: String? = nil,
                     action: (() -> Void)? = nil,
                     secondaryLabel: String? = nil,
                     secondaryAction: (() -> Void)? = nil,
                     duration: TimeInterval = 8) {
        dismiss()
        let view = ToastView(
            message: message, systemImage: systemImage,
            actionLabel: actionLabel, duration: duration,
            secondaryLabel: secondaryLabel,
            action: {
                action?()
                dismiss()
            },
            secondaryAction: secondaryAction.map { run in { run() } },
            onClose: { dismiss() },
            onHoverChanged: { hovering in
                // The toast is STATIC while visible — sized once at show for
                // its full content, never resized after (a hover-grow +
                // window-follow scheme made text escape the capsule and the
                // whole pill jitter). Hovering only holds it open.
                if hovering {
                    dismissTask?.cancel()
                } else {
                    dismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
                }
            }
        )
        let toast = FloatingPanel(content: view, fixedSize: true)
        toast.onDismiss = { panel = nil }
        panel = toast
        guard let screen = NSScreen.main else { return }
        var size = NSSize(width: 440, height: 64)
        toast.setFrame(NSRect(origin: .zero, size: size), display: false)
        toast.layoutIfNeeded()
        let measured = toast.contentIdeal
        if measured.width > 1, measured.height > 1 { size = measured }
        let visible = screen.visibleFrame
        toast.setFrame(
            NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                   width: size.width, height: size.height),
            display: true
        )
        toast.orderFrontRegardless()

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    static func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String
    let actionLabel: String?
    let duration: TimeInterval
    var secondaryLabel: String?
    var action: () -> Void
    var secondaryAction: (() -> Void)?
    var onClose: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(MM.Colors.accent)
            Text(message)
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
            if let secondaryLabel, let secondaryAction {
                Button(secondaryLabel, action: secondaryAction)
                    .buttonStyle(.plain)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .clickable(minSize: 24)
            }
            if let actionLabel {
                Button {
                    action()
                } label: {
                    Text(actionLabel)
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(MM.Colors.textPrimary))
                        .clickable(minSize: 24)
                }
                .buttonStyle(.plain)
            }
            IconView(icon: .close, size: 14, color: MM.Colors.textTertiary)
                .clickable(minSize: 22)
                .onTapGesture { onClose() }
                .opacity(hovering ? 1 : 0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(MM.Colors.background)
                .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
        )
        .overlay(alignment: .bottom) {
            if !hovering {
                CountdownBar(duration: duration, color: MM.Colors.accent.opacity(0.6))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 3)
            }
        }
        // Hover only toggles opacities (✕, countdown) — nothing size-affecting,
        // so the window frame set at show() stays valid for the toast's life.
        .animation(MM.Motion.gentle, value: hovering)
        .onHover { h in
            hovering = h
            onHoverChanged(h)
        }
    }
}
