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

/// The ShittyFriends palette: warm paper, deep ink, and loud identity colors. Never "black + orange".
enum Palette {
    static let paper = Color.adaptive(light: 0xFFF3DF, dark: 0x16111D)
    static let paper2 = Color.adaptive(light: 0xFFE9C7, dark: 0x211A2B)
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x251D31)
    static let ink = Color.adaptive(light: 0x17121F, dark: 0xFFF3DF)
    /// Always-dark ink for text on saturated fills (they stay bright in dark mode too).
    static let inkFixed = Color(hex: 0x17121F)
    static let muted = Color.adaptive(light: 0x6C6178, dark: 0xB3A8C2)
    static let line = Color.adaptive(light: 0x17121F, dark: 0x0A070D)

    static let poop = Color(hex: 0x7A4A24)
    static let sun = Color(hex: 0xFFD02E)
    static let pink = Color(hex: 0xFF2E93)
    static let blue = Color(hex: 0x2F5BFF)
    static let lime = Color(hex: 0xB8F43A)
    static let violet = Color(hex: 0x8A4DFF)
    static let tomato = Color(hex: 0xFF4436)
    static let aqua = Color(hex: 0x12D9C4)
    static let tangerine = Color(hex: 0xFF7A1A)

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
    /// Huge expanded black display type ("TUESDAY", "POOPING").
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
    static let stroke: CGFloat = 2.5
    static let radius: CGFloat = 22
    static let shadow: CGFloat = 5
    static let gutter: CGFloat = 18
}

enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.5)
    static let slam = Animation.spring(response: 0.22, dampingFraction: 0.45)
    static let soft = Animation.spring(response: 0.5, dampingFraction: 0.82)
}
