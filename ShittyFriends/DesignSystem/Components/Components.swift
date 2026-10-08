import SwiftUI
import UIKit

// MARK: - Surfaces

/// Graphic sticker treatment. Deliberately lighter than the original implementation.
/// Use this for moments that should feel playful or collectible, not for every container.
struct Sticker: ViewModifier {
    var fill: Color
    var radius: CGFloat = Metrics.radius
    var shadow: CGFloat = Metrics.shadow
    var stroke: CGFloat = Metrics.stroke

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line, lineWidth: stroke))
            )
            .background {
                if shadow > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Palette.line)
                        .offset(x: 0, y: shadow)
                }
            }
    }
}

/// Calm high-contrast surface for everyday information. No fake depth, just a crisp edge.
struct CalmSurface: ViewModifier {
    var fill: Color = Palette.card
    var radius: CGFloat = 20
    var outlined: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(outlined ? Palette.hairline : Color.clear, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func sticker(_ fill: Color = Palette.card, radius: CGFloat = Metrics.radius, shadow: CGFloat = Metrics.shadow, stroke: CGFloat = Metrics.stroke) -> some View {
        modifier(Sticker(fill: fill, radius: radius, shadow: shadow, stroke: stroke))
    }

    func calmSurface(_ fill: Color = Palette.card, radius: CGFloat = 20, outlined: Bool = true) -> some View {
        modifier(CalmSurface(fill: fill, radius: radius, outlined: outlined))
    }
}

/// Tactile button. The button still has character, but no longer carries a giant hard shadow by default.
struct StickerButtonStyle: ButtonStyle {
    var fill: Color = Palette.ink
    var ink: Color = Palette.paper
    var radius: CGFloat = 20
    var height: CGFloat = 56
    var font: Font = .heading(17)
    var fullWidth = true
    var shadow: CGFloat = Metrics.shadow

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(font)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line, lineWidth: Metrics.stroke))
            )
            .offset(y: pressed ? max(0, shadow - 1) : 0)
            .background {
                if shadow > 0 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Palette.line)
                        .offset(y: shadow)
                }
            }
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(Motion.snappy, value: pressed)
            .onChange(of: pressed) { _, isPressed in if isPressed { Haptics.press() } }
    }
}

extension ButtonStyle where Self == StickerButtonStyle {
    static func sticker(_ fill: Color = Palette.sun, ink: Color = Palette.inkFixed, height: CGFloat = 56, fullWidth: Bool = true) -> StickerButtonStyle {
        StickerButtonStyle(fill: fill, ink: ink, height: height, fullWidth: fullWidth)
    }

    static var stickerSmall: StickerButtonStyle {
        StickerButtonStyle(fill: Palette.card, ink: Palette.ink, radius: 16, height: 40, font: .heading(12), fullWidth: false, shadow: 0)
    }
}

/// Plain press feedback for custom tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Text bits

struct SectionTitle: View {
    var text: String
    var trailing: String?
    var action: (() -> Void)?

    init(_ text: String, trailing: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.heading(13))
                .tracking(1.1)
                .foregroundStyle(Palette.ink)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(.heading(11))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.paper2))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .buttonStyle(PressableStyle())
            }
        }
    }
}

struct Chip: View {
    var text: String
    var fill: Color = Palette.card
    var ink: Color = Palette.ink
    var selected = false

    var body: some View {
        Text(text)
            .font(.heading(11))
            .foregroundStyle(selected ? Palette.paper : ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Palette.ink : fill))
            .overlay(Capsule().strokeBorder(selected ? Palette.ink : Palette.hairline, lineWidth: 1))
    }
}

/// "@handle" in the house style.
struct HandleText: View {
    var handle: String
    var size: CGFloat = 16
    var color: Color = Palette.ink

    var body: some View {
        Text(handle.hasPrefix("@") ? handle : "@" + handle)
            .font(.heading(size))
            .foregroundStyle(color)
            .lineLimit(1)
            // Handles go up to 20 characters in a wide, heavy face: shrink before truncating.
            .minimumScaleFactor(0.45)
    }
}

struct EmptyState: View {
    var emoji: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Text(emoji).font(.system(size: 46))
            Text(title).font(.heading(17)).multilineTextAlignment(.center)
            Text(message).font(.ui(14, .medium)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.ink)
        .padding(22)
        .frame(maxWidth: .infinity)
    }
}

/// Big number that slams in when it changes.
struct SlamNumber: View {
    var value: Int
    var size: CGFloat = 64
    var color: Color = Palette.ink

    var body: some View {
        Text("\(value)")
            .font(.digits(size))
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(value)))
            .animation(Motion.slam, value: value)
    }
}

/// Live timer text from a start date (reconstructed from timestamps, never a foreground-only timer).
struct TimerText: View {
    var start: Date
    var end: Date?
    var size: CGFloat = 56
    var color: Color = Palette.ink

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let t = (end ?? context.date).timeIntervalSince(start)
            Text(StatsCalculator.formatDuration(max(0, t)))
                .font(.digits(size))
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Background

/// A quiet paper canvas with optional slow identity glow. The default is intentionally near-static.
struct BlobBackground: View {
    var colors: [Color] = [Palette.sun, Palette.pink, Palette.blue]
    var intensity: Double = 0.08

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 8)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.paper))
                for (i, c) in colors.prefix(3).enumerated() {
                    let phase = Double(i) * 1.9
                    let x = size.width * (0.5 + 0.34 * sin(t * 0.018 + phase))
                    let y = size.height * (0.46 + 0.28 * cos(t * 0.014 + phase * 1.2))
                    let r = max(size.width, size.height) * (0.28 + 0.03 * sin(t * 0.02 + phase))
                    ctx.opacity = intensity
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .radialGradient(Gradient(colors: [c, c.opacity(0)]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.toasts.suffix(3)) { toast in
                ToastRow(toast: toast)
                    .transition(.move(edge: .top).combined(with: .scale(scale: 0.92)).combined(with: .opacity))
                    .onTapGesture { model.toasts.removeAll { $0.id == toast.id } }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .animation(Motion.bouncy, value: model.toasts)
    }
}

struct ToastRow: View {
    var toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.heading(13)).foregroundStyle(Palette.ink)
                if !toast.body.isEmpty {
                    Text(toast.body).font(.ui(13, .medium)).foregroundStyle(Palette.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Circle().fill(fill).frame(width: 9, height: 9)
        }
        .padding(12)
        .calmSurface(Palette.card, radius: 18)
    }

    @ViewBuilder private var leading: some View {
        switch toast.style {
        case .achievement(let id): Object3DImage(subject: .trophy(id.object), size: 38)
        case .cosmetic(let id): Object3DImage(subject: .poop(id), size: 38)
        case .error: Text("⚠️").font(.system(size: 26))
        case .social: Text("🤝").font(.system(size: 26))
        case .info: Text("💩").font(.system(size: 26))
        }
    }

    private var fill: Color {
        switch toast.style {
        case .achievement: return Palette.sun
        case .cosmetic(let id): return Palette.rarity(id.rarity)
        case .error: return Palette.tomato
        case .social: return Palette.aqua
        case .info: return Palette.lime
        }
    }
}

// MARK: - Misc helpers

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}

extension View {
    /// Standard horizontal page padding.
    func gutter() -> some View { padding(.horizontal, Metrics.gutter) }
}

/// Jumps to this app's page in iOS Settings — the only way back after a permission was denied.
struct OpenSystemSettingsButton: View {
    var title: String = "Open iOS Settings"

    var body: some View {
        Button(title) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

// MARK: - Floating tab bar clearance

private struct TabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Height of the floating tab bar (+ live-session bar) that sits on top of tab content.
    /// 0 outside the tab shell (sheets, covers, onboarding).
    var tabBarClearance: CGFloat {
        get { self[TabBarClearanceKey.self] }
        set { self[TabBarClearanceKey.self] = newValue }
    }
}

/// Reserves room for the floating tab bar directly on a scroll view / form, so its last rows can
/// always scroll fully above the bar. Applied per screen (inside each NavigationStack) because an
/// inset set outside a NavigationStack is not reliably honoured by the scroll views inside it.
private struct TabBarClearanceModifier: ViewModifier {
    @Environment(\.tabBarClearance) private var clearance

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: clearance)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Use on every scrollable screen that can appear under the floating tab bar.
    func clearsTabBar() -> some View { modifier(TabBarClearanceModifier()) }
}
