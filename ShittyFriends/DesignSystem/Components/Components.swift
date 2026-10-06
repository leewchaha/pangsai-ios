import SwiftUI

// MARK: - Sticker surfaces

/// The signature look: saturated fill, thick ink outline, hard offset shadow.
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
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.line)
                    .offset(x: 0, y: shadow)
            )
    }
}

extension View {
    func sticker(_ fill: Color = Palette.card, radius: CGFloat = Metrics.radius, shadow: CGFloat = Metrics.shadow, stroke: CGFloat = Metrics.stroke) -> some View {
        modifier(Sticker(fill: fill, radius: radius, shadow: shadow, stroke: stroke))
    }
}

/// Tactile button: compresses into its shadow when pressed.
struct StickerButtonStyle: ButtonStyle {
    var fill: Color = Palette.sun
    var ink: Color = Palette.inkFixed
    var radius: CGFloat = 20
    var height: CGFloat = 58
    var font: Font = .heading(17)
    var fullWidth = true

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
            .offset(y: pressed ? Metrics.shadow - 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.line)
                    .offset(y: Metrics.shadow)
            )
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(Motion.snappy, value: pressed)
            .onChange(of: pressed) { _, isPressed in if isPressed { Haptics.press() } }
    }
}

extension ButtonStyle where Self == StickerButtonStyle {
    static func sticker(_ fill: Color = Palette.sun, ink: Color = Palette.inkFixed, height: CGFloat = 58, fullWidth: Bool = true) -> StickerButtonStyle {
        StickerButtonStyle(fill: fill, ink: ink, height: height, fullWidth: fullWidth)
    }

    static var stickerSmall: StickerButtonStyle {
        StickerButtonStyle(fill: Palette.card, ink: Palette.ink, radius: 16, height: 42, font: .heading(13), fullWidth: false)
    }
}

/// Plain press feedback for custom tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
                .font(.heading(15))
                .tracking(1.5)
                .foregroundStyle(Palette.ink)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(.heading(12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .sticker(Palette.card, radius: 12, shadow: 3, stroke: 2)
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
            .font(.heading(12))
            .foregroundStyle(selected ? Palette.inkFixed : ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Palette.sun : fill))
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 2))
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
            .minimumScaleFactor(0.6)
    }
}

struct EmptyState: View {
    var emoji: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Text(emoji).font(.system(size: 54))
            Text(title).font(.heading(18)).multilineTextAlignment(.center)
            Text(message).font(.ui(15, .medium)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
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

/// Warm paper with slow-floating identity-color blobs. Makes screens feel alive without a feed.
struct BlobBackground: View {
    var colors: [Color] = [Palette.sun, Palette.pink, Palette.blue]
    var intensity: Double = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.paper))
                for (i, c) in colors.prefix(5).enumerated() {
                    let phase = Double(i) * 1.7
                    let x = size.width * (0.5 + 0.38 * sin(t * 0.07 + phase))
                    let y = size.height * (0.45 + 0.35 * cos(t * 0.05 + phase * 1.3))
                    let r = max(size.width, size.height) * (0.32 + 0.06 * sin(t * 0.11 + phase))
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
                    .transition(.move(edge: .top).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
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
                Text(toast.title).font(.heading(14)).foregroundStyle(Palette.inkFixed)
                if !toast.body.isEmpty {
                    Text(toast.body).font(.ui(13, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.8)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .sticker(fill, radius: 18, shadow: 4)
    }

    @ViewBuilder private var leading: some View {
        switch toast.style {
        case .achievement(let id): Object3DImage(subject: .trophy(id.object), size: 44)
        case .cosmetic(let id): Object3DImage(subject: .poop(id), size: 44)
        case .error: Text("⚠️").font(.system(size: 30))
        case .social: Text("🤝").font(.system(size: 30))
        case .info: Text("💩").font(.system(size: 30))
        }
    }

    private var fill: Color {
        switch toast.style {
        case .achievement: return Palette.sun
        case .cosmetic(let id): return Palette.rarity(id.rarity).opacity(0.9)
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
