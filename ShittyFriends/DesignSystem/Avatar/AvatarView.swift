import SwiftUI

/// Stylized avatar drawn from an `AvatarSpec`: a face shape in a skin/absurd tone on the person's
/// identity color, with preset eyes, mouth and accessory. No photos.
struct AvatarView: View {
    var spec: AvatarSpec
    var color: IdentityColor
    var size: CGFloat = 56
    var ring: Bool = true

    var body: some View {
        Canvas { ctx, sz in
            AvatarPainter.paint(spec: spec, color: color, ring: ring, in: &ctx, size: sz)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension AvatarView {
    init(person: PersonRef, size: CGFloat = 56, ring: Bool = true) {
        self.init(spec: person.avatar, color: person.color, size: size, ring: ring)
    }
}

enum AvatarPainter {
    static func paint(spec: AvatarSpec, color: IdentityColor, ring: Bool, in ctx: inout GraphicsContext, size sz: CGSize) {
        let s = min(sz.width, sz.height)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
        let ink = Color(hex: 0x17121F)
        let line = max(1.2, s * 0.03)
        let stroke = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)

        // Background disc in identity color
        let disc = Path(ellipseIn: r(0.02, 0.02, 0.96, 0.96))
        ctx.fill(disc, with: .color(color.color))
        if ring { ctx.stroke(disc, with: .color(ink), lineWidth: line) }

        // Accessories that sit behind the head
        if spec.accessory == .halo {
            let halo = Path(ellipseIn: r(0.3, 0.08, 0.4, 0.12))
            ctx.stroke(halo, with: .color(Color(hex: 0xFFD02E)), lineWidth: line * 1.6)
        }

        // Face
        let tone = Color(hex: spec.toneHex)
        let face: Path
        switch spec.shape {
        case .round:
            face = Path(ellipseIn: r(0.17, 0.2, 0.66, 0.66))
        case .squircle:
            face = Path(roundedRect: r(0.17, 0.22, 0.66, 0.62), cornerRadius: s * 0.2, style: .continuous)
        case .blob:
            var b = Path()
            let c = p(0.5, 0.54)
            let n = 9
            for i in 0...n * 4 {
                let t = CGFloat(i) / CGFloat(n * 4) * 2 * .pi
                let rr = s * (0.31 + 0.025 * sin(t * CGFloat(n) / 2 + 0.6))
                let pt = CGPoint(x: c.x + cos(t) * rr, y: c.y + sin(t) * rr * 1.04)
                if i == 0 { b.move(to: pt) } else { b.addLine(to: pt) }
            }
            b.closeSubpath()
            face = b
        case .bean:
            face = Path(ellipseIn: r(0.2, 0.16, 0.6, 0.72))
        case .tall:
            face = Path(roundedRect: r(0.24, 0.14, 0.52, 0.76), cornerRadius: s * 0.26, style: .continuous)
        }
        ctx.fill(face, with: .color(tone))
        ctx.stroke(face, with: .color(ink), lineWidth: line)

        // Cheeks
        for x in [0.3, 0.7] as [CGFloat] {
            ctx.fill(Path(ellipseIn: r(x - 0.06, 0.6, 0.12, 0.06)), with: .color(Color(hex: 0xFF5A8A, opacity: 0.35)))
        }

        // Eyes
        let eyeY: CGFloat = 0.5
        let eyeXs: [CGFloat] = [0.39, 0.61]
        switch spec.eyes {
        case .dots:
            for x in eyeXs { ctx.fill(Path(ellipseIn: r(x - 0.04, eyeY - 0.05, 0.08, 0.1)), with: .color(ink)) }
        case .happy:
            for x in eyeXs {
                var a = Path()
                a.addArc(center: p(x, eyeY + 0.02), radius: s * 0.05, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                ctx.stroke(a, with: .color(ink), style: stroke)
            }
        case .wide:
            for x in eyeXs {
                let w = Path(ellipseIn: r(x - 0.075, eyeY - 0.075, 0.15, 0.15))
                ctx.fill(w, with: .color(.white))
                ctx.stroke(w, with: .color(ink), lineWidth: line * 0.8)
                ctx.fill(Path(ellipseIn: r(x - 0.035, eyeY - 0.025, 0.07, 0.07)), with: .color(ink))
            }
        case .sleepy:
            for x in eyeXs {
                var l = Path()
                l.move(to: p(x - 0.05, eyeY + 0.01))
                l.addQuadCurve(to: p(x + 0.05, eyeY + 0.01), control: p(x, eyeY + 0.05))
                ctx.stroke(l, with: .color(ink), style: stroke)
            }
        case .wink:
            ctx.fill(Path(ellipseIn: r(eyeXs[0] - 0.04, eyeY - 0.05, 0.08, 0.1)), with: .color(ink))
            var w = Path()
            w.move(to: p(eyeXs[1] - 0.05, eyeY + 0.02))
            w.addLine(to: p(eyeXs[1], eyeY - 0.03))
            w.addLine(to: p(eyeXs[1] + 0.05, eyeY + 0.02))
            ctx.stroke(w, with: .color(ink), style: stroke)
        case .stars:
            for x in eyeXs { ctx.fill(star(center: p(x, eyeY), radius: s * 0.065), with: .color(Color(hex: 0xFFD02E))); ctx.stroke(star(center: p(x, eyeY), radius: s * 0.065), with: .color(ink), lineWidth: line * 0.6) }
        case .angry:
            for (i, x) in eyeXs.enumerated() {
                ctx.fill(Path(ellipseIn: r(x - 0.035, eyeY - 0.03, 0.07, 0.08)), with: .color(ink))
                var brow = Path()
                let dir: CGFloat = i == 0 ? 1 : -1
                brow.move(to: p(x - 0.06 * dir, eyeY - 0.1))
                brow.addLine(to: p(x + 0.05 * dir, eyeY - 0.06))
                ctx.stroke(brow, with: .color(ink), style: stroke)
            }
        }

        // Mouth
        let my: CGFloat = 0.66
        switch spec.mouth {
        case .smile:
            var m = Path()
            m.move(to: p(0.41, my))
            m.addQuadCurve(to: p(0.59, my), control: p(0.5, my + 0.08))
            ctx.stroke(m, with: .color(ink), style: stroke)
        case .grin:
            var m = Path()
            m.move(to: p(0.38, my - 0.01))
            m.addQuadCurve(to: p(0.62, my - 0.01), control: p(0.5, my + 0.15))
            m.closeSubpath()
            ctx.fill(m, with: .color(ink))
        case .flat:
            var m = Path()
            m.move(to: p(0.43, my + 0.01))
            m.addLine(to: p(0.57, my + 0.01))
            ctx.stroke(m, with: .color(ink), style: stroke)
        case .oh:
            ctx.stroke(Path(ellipseIn: r(0.46, my - 0.025, 0.08, 0.09)), with: .color(ink), lineWidth: line)
        case .tongue:
            var m = Path()
            m.move(to: p(0.4, my - 0.01))
            m.addQuadCurve(to: p(0.6, my - 0.01), control: p(0.5, my + 0.1))
            ctx.stroke(m, with: .color(ink), style: stroke)
            let t = Path(roundedRect: r(0.5, my + 0.01, 0.07, 0.08), cornerRadius: s * 0.035)
            ctx.fill(t, with: .color(Color(hex: 0xFF5A8A)))
            ctx.stroke(t, with: .color(ink), lineWidth: line * 0.7)
        case .smirk:
            var m = Path()
            m.move(to: p(0.42, my + 0.02))
            m.addQuadCurve(to: p(0.6, my - 0.02), control: p(0.53, my + 0.06))
            ctx.stroke(m, with: .color(ink), style: stroke)
        case .teeth:
            let t = Path(roundedRect: r(0.4, my - 0.03, 0.2, 0.08), cornerRadius: s * 0.03)
            ctx.fill(t, with: .color(.white))
            ctx.stroke(t, with: .color(ink), lineWidth: line * 0.8)
            var mid = Path()
            mid.move(to: p(0.4, my + 0.01))
            mid.addLine(to: p(0.6, my + 0.01))
            ctx.stroke(mid, with: .color(ink), lineWidth: line * 0.5)
        }

        // Accessories on top
        let gold = Color(hex: 0xFFD02E)
        switch spec.accessory {
        case .none, .halo:
            break
        case .cap:
            var cap = Path()
            cap.addArc(center: p(0.5, 0.33), radius: s * 0.24, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            cap.closeSubpath()
            ctx.fill(cap, with: .color(Color(hex: 0xFF4436)))
            ctx.stroke(cap, with: .color(ink), lineWidth: line)
            let brim = Path(roundedRect: r(0.45, 0.3, 0.38, 0.06), cornerRadius: s * 0.03)
            ctx.fill(brim, with: .color(Color(hex: 0xFF4436)))
            ctx.stroke(brim, with: .color(ink), lineWidth: line)
        case .crown:
            var c = Path()
            c.move(to: p(0.32, 0.27))
            c.addLine(to: p(0.32, 0.12))
            c.addLine(to: p(0.41, 0.2))
            c.addLine(to: p(0.5, 0.08))
            c.addLine(to: p(0.59, 0.2))
            c.addLine(to: p(0.68, 0.12))
            c.addLine(to: p(0.68, 0.27))
            c.closeSubpath()
            ctx.fill(c, with: .color(gold))
            ctx.stroke(c, with: .color(ink), lineWidth: line)
        case .headphones:
            var band = Path()
            band.addArc(center: p(0.5, 0.5), radius: s * 0.36, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
            ctx.stroke(band, with: .color(ink), style: StrokeStyle(lineWidth: line * 2.2, lineCap: .round))
            for x in [0.1, 0.78] as [CGFloat] {
                let cup = Path(roundedRect: r(x, 0.42, 0.12, 0.2), cornerRadius: s * 0.05)
                ctx.fill(cup, with: .color(Color(hex: 0x2F5BFF)))
                ctx.stroke(cup, with: .color(ink), lineWidth: line)
            }
        case .glasses:
            for x in eyeXs {
                ctx.stroke(Path(ellipseIn: r(x - 0.085, eyeY - 0.085, 0.17, 0.17)), with: .color(ink), lineWidth: line)
            }
            var bridge = Path()
            bridge.move(to: p(0.475, eyeY - 0.01))
            bridge.addLine(to: p(0.525, eyeY - 0.01))
            ctx.stroke(bridge, with: .color(ink), lineWidth: line)
        case .shades:
            for x in eyeXs {
                let lens = Path(roundedRect: r(x - 0.09, eyeY - 0.06, 0.18, 0.11), cornerRadius: s * 0.04)
                ctx.fill(lens, with: .color(ink))
            }
            var bridge = Path()
            bridge.move(to: p(0.46, eyeY - 0.03))
            bridge.addLine(to: p(0.54, eyeY - 0.03))
            ctx.stroke(bridge, with: .color(ink), lineWidth: line)
        case .bow:
            let pink = Color(hex: 0xFF2E93)
            var left = Path()
            left.move(to: p(0.66, 0.22))
            left.addLine(to: p(0.56, 0.14))
            left.addLine(to: p(0.56, 0.3))
            left.closeSubpath()
            var right = Path()
            right.move(to: p(0.66, 0.22))
            right.addLine(to: p(0.76, 0.14))
            right.addLine(to: p(0.76, 0.3))
            right.closeSubpath()
            for b in [left, right] { ctx.fill(b, with: .color(pink)); ctx.stroke(b, with: .color(ink), lineWidth: line * 0.8) }
            ctx.fill(Path(ellipseIn: r(0.635, 0.19, 0.06, 0.06)), with: .color(pink))
        case .beanie:
            var dome = Path()
            dome.addArc(center: p(0.5, 0.34), radius: s * 0.25, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            dome.closeSubpath()
            ctx.fill(dome, with: .color(Color(hex: 0x12D9C4)))
            ctx.stroke(dome, with: .color(ink), lineWidth: line)
            let band = Path(roundedRect: r(0.24, 0.3, 0.52, 0.08), cornerRadius: s * 0.03)
            ctx.fill(band, with: .color(Color(hex: 0x0E9E8F)))
            ctx.stroke(band, with: .color(ink), lineWidth: line)
            let pom = Path(ellipseIn: r(0.45, 0.04, 0.1, 0.1))
            ctx.fill(pom, with: .color(.white))
            ctx.stroke(pom, with: .color(ink), lineWidth: line * 0.8)
        case .horns:
            for (a, b, c) in [(0.3, 0.3, 0.26), (0.7, 0.74, 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
                var h = Path()
                h.move(to: p(a - 0.06, 0.28))
                h.addLine(to: p(b, 0.08))
                h.addLine(to: p(c + 0.06, 0.26))
                h.closeSubpath()
                ctx.fill(h, with: .color(Color(hex: 0xE0201B)))
                ctx.stroke(h, with: .color(ink), lineWidth: line * 0.8)
            }
        }
    }

    static func star(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for i in 0..<10 {
            let rr = i % 2 == 0 ? radius : radius * 0.45
            let a = CGFloat(i) / 10 * 2 * .pi - .pi / 2
            let pt = CGPoint(x: center.x + cos(a) * rr, y: center.y + sin(a) * rr)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}
