import AppKit
import SwiftUI

/// Chat-panel colors: light values follow the design; dark values are derived from them.
enum Palette {
    /// Green for text, borders and icons.
    static let accent = dynamic(light: 0x3A6650, dark: 0x7FB596)
    /// Solid green behind white text (Send button).
    static let accentFill = dynamic(light: 0x3A6650, dark: 0x4E8466)
    /// Soft sage fill: user bubble, Chat menu, paw tile.
    static let sage = dynamic(light: 0xE8EFE8, dark: 0x2E3A32)
    static let panelBackground = dynamic(light: 0xF7F7F5, dark: 0x1E1F1E)
    static let headerBackground = dynamic(light: 0xFFFFFF, dark: 0x252625)
    static let secondaryText = dynamic(light: 0x6B6B6B, dark: 0xA0A0A0)
    /// Chip and Close button borders.
    static let border = dynamic(light: 0xD9D9D6, dark: 0x3A3B3A)
    /// Capture / Paste button fill.
    static let secondaryFill = dynamic(light: 0xF2F2F0, dark: 0x2A2B2A)
    /// Error bar fill. ponytail: the design has no error styling; a soft red tint stands in.
    static let errorFill = dynamic(light: 0xFBEAEA, dark: 0x3A2626)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
