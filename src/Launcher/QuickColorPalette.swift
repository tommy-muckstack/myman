import AppKit
import SwiftUI

enum QuickColorPalette {
    /// A complementary accent, two softer neighboring shades and a dark anchor.
    /// Near-neutrals use a muted blue family instead of amplifying tiny RGB noise.
    static func companions(for hex: String) -> [String] {
        let rgb = components(hex)
        let maximum = max(rgb.0, rgb.1, rgb.2), minimum = min(rgb.0, rgb.1, rgb.2)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        var hue = 0.0
        if delta > 0 {
            if maximum == rgb.0 { hue = ((rgb.1 - rgb.2) / delta).truncatingRemainder(dividingBy: 6) / 6 }
            else if maximum == rgb.1 { hue = ((rgb.2 - rgb.0) / delta + 2) / 6 }
            else { hue = ((rgb.0 - rgb.1) / delta + 4) / 6 }
        }
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let neutral = delta < 0.06
        let complement = neutral ? 0.60 : hue + 0.5
        let strength = neutral ? 0.28 : min(0.72, max(0.32, saturation * 0.8))
        return [
            color(hue: complement, saturation: strength, lightness: 0.48),
            color(hue: complement - 1 / 12, saturation: strength * 0.75, lightness: 0.70),
            color(hue: complement + 1 / 12, saturation: strength * 0.45, lightness: 0.90),
            color(hue: complement, saturation: strength * 0.5, lightness: 0.20)
        ]
    }

    static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }

    private static func color(hue: Double, saturation: Double, lightness: Double) -> String {
        let h = (hue - floor(hue)) * 6
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2
        let channels: (Double, Double, Double)
        switch h {
        case ..<1: channels = (chroma, x, 0)
        case ..<2: channels = (x, chroma, 0)
        case ..<3: channels = (0, chroma, x)
        case ..<4: channels = (0, x, chroma)
        case ..<5: channels = (x, 0, chroma)
        default: channels = (chroma, 0, x)
        }
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value + match)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(channels.0), byte(channels.1), byte(channels.2))
    }
}

struct QuickColorPaletteView: View {
    let hex: String
    var onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack(spacing: MM.Layout.spacing) {
                swatch(hex).frame(width: 36, height: 36)
                Text(hex).font(MM.Fonts.title).textSelection(.enabled)
                Spacer()
            }
            Text("Pairs well with").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            HStack(spacing: MM.Layout.spacing) {
                ForEach(QuickColorPalette.companions(for: hex), id: \.self) { color in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(color, forType: .string)
                        onCopy(color)
                    } label: {
                        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                            swatch(color).frame(height: 36)
                            Text(color).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                        }.frame(maxWidth: .infinity).clickable()
                    }.buttonStyle(.plain).help("Copy \(color)").accessibilityLabel("Copy \(color)")
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let rgb = QuickColorPalette.components(hex)
        // Palette colors are user-derived data, not interface design tokens.
        return RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
            .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border))
            .accessibilityLabel(hex)
    }
}
