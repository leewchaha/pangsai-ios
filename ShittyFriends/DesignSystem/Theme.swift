import SwiftUI
import UIKit

// MARK: - Color

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Light/dark adaptive color.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// High-contrast, playful palette inspired by the calm canvas / loud state-change rhythm of social map apps.
/// Neutral surfaces dominate; identity colors are reserved for people, live states, rewards, and key actions.
enum Palette {
    static let paper = Color.adaptive(light: 0xF7F7F2, dark: 0x111111)
    static let paper2 = Color.adaptive(light: 0xECECE6, dark: 0x1B1B1B)
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x1D1D1D)
    static let ink = Color.adaptive(light: 0x101010, dark: 0xF8F8F3)
    /// Always-dark ink for text on bright saturated fills.
    static let inkFixed = Color(hex: 0x101010)
    static let muted = Color.adaptive(light: 0x6A6A66, dark: 0xA9A9A3)
    static let line = Color.adaptive(light: 0x101010, dark: 0xF8F8F3)
    static let hairline = Color.adaptive(light: 0xD8D8D2, dark: 0x343434)

    static let poop = Color(hex: 0x7A4A24)
    static let sun = Color(hex: 0xFFD82E)
    static let pink = Color(hex: 0xFF3B9D)
    static let blue = Color(hex: 0x3967FF)
    static let lime = Color(hex: 0xB9F33D)
    static let violet = Color(hex: 0x8757FF)
    static let tomato = Color(hex: 0xFF4C3E)
    static let aqua = Color(hex: 0x25DCC8)
    static let tangerine = Color(hex: 0xFF8128)

    static func rarity(_ r: Rarity) -> Color {
        switch r {
        case .common: return Color(hex: 0xC9BFAE)
        case .rare: return blue
        case .epic: return violet
        case .legendary: return sun
        }
    }
}

extension IdentityColor {
    var color: Color { Color(hex: hex) }
    /// Text color that reads on top of this color.
    var ink: Color { prefersDarkInk ? Palette.inkFixed : .white }
}

// MARK: - Type

extension Font {
    /// Display type is intentionally rare. Use it for one hero per screen, not every label.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .default).width(.expanded)
    }

    /// Section titles and button labels.
    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default).width(.expanded)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Timers and counters: rounded, tabular digits.
    static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded).monospacedDigit()
    }
}

// MARK: - Metrics & motion

enum Metrics {
    /// The old UI used 2.5pt outlines and 5pt hard shadows almost everywhere. Keep the graphic language,
    /// but make it an accent rather than the default visual weight.
    static let stroke: CGFloat = 1.5
    static let radius: CGFloat = 20
    static let shadow: CGFloat = 2
    static let gutter: CGFloat = 18
}

enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.72)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let slam = Animation.spring(response: 0.22, dampingFraction: 0.5)
    static let soft = Animation.spring(response: 0.5, dampingFraction: 0.86)
}
