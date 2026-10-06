import UIKit

/// Procedurally drawn textures for 3D materials. Drawn once, cached.
enum Textures {
    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    private static func cached(_ key: String, _ make: () -> UIImage) -> UIImage {
        lock.lock()
        if let img = cache[key] { lock.unlock(); return img }
        lock.unlock()
        let img = make()
        lock.lock()
        cache[key] = img
        lock.unlock()
        return img
    }

    private static func render(_ size: CGSize, _ draw: (CGContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in draw(ctx.cgContext, size) }
    }

    /// Deterministic pseudo-random sequence so textures look the same on every launch.
    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
        }
    }

    /// Studio-style environment map (equirectangular) for glossy reflections.
    static var studio: UIImage {
        cached("studio") {
            render(CGSize(width: 1024, height: 512)) { c, s in
                let colors = [UIColor(white: 1.0, alpha: 1).cgColor, UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1).cgColor, UIColor(white: 0.22, alpha: 1).cgColor, UIColor(white: 0.05, alpha: 1).cgColor]
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.35, 0.62, 1])!
                c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: s.height), options: [])
                // Softboxes give the crisp highlights glossy/chrome materials need.
                c.setFillColor(UIColor(white: 1, alpha: 1).cgColor)
                c.fill(CGRect(x: s.width * 0.18, y: s.height * 0.14, width: s.width * 0.12, height: s.height * 0.22))
                c.fill(CGRect(x: s.width * 0.62, y: s.height * 0.10, width: s.width * 0.20, height: s.height * 0.12))
                c.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1).cgColor)
                c.fill(CGRect(x: s.width * 0.42, y: s.height * 0.30, width: s.width * 0.05, height: s.height * 0.16))
                c.setFillColor(UIColor(red: 0.6, green: 0.8, blue: 1, alpha: 1).cgColor)
                c.fill(CGRect(x: s.width * 0.88, y: s.height * 0.26, width: s.width * 0.06, height: s.height * 0.14))
            }
        }
    }

    static var galaxy: UIImage {
        cached("galaxy") {
            render(CGSize(width: 512, height: 512)) { c, s in
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(red: 0.08, green: 0.02, blue: 0.22, alpha: 1).cgColor, UIColor(red: 0.36, green: 0.05, blue: 0.52, alpha: 1).cgColor, UIColor(red: 0.02, green: 0.15, blue: 0.40, alpha: 1).cgColor] as CFArray, locations: [0, 0.5, 1])!
                c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: s.width, y: s.height), options: [])
                var r = Rand(state: 42)
                for _ in 0..<26 {
                    let x = r.next() * s.width, y = r.next() * s.height, rad = 30 + r.next() * 90
                    let hue = 0.6 + r.next() * 0.35
                    let col = UIColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1)), saturation: 0.9, brightness: 0.8, alpha: 0.28).cgColor
                    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [col, UIColor.clear.cgColor] as CFArray, locations: [0, 1])!
                    c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
                }
                for _ in 0..<420 {
                    let x = r.next() * s.width, y = r.next() * s.height, size = 0.6 + r.next() * 2.4
                    c.setFillColor(UIColor(white: 1, alpha: 0.5 + r.next() * 0.5).cgColor)
                    c.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
                }
            }
        }
    }

    /// Emission map for lava: bright cracks on black.
    static var lavaCracks: UIImage {
        cached("lava") {
            render(CGSize(width: 512, height: 512)) { c, s in
                c.setFillColor(UIColor.black.cgColor)
                c.fill(CGRect(origin: .zero, size: s))
                var r = Rand(state: 7)
                c.setLineCap(.round)
                c.setLineJoin(.round)
                for _ in 0..<38 {
                    var p = CGPoint(x: r.next() * s.width, y: r.next() * s.height)
                    c.move(to: p)
                    for _ in 0..<6 {
                        p.x += (r.next() - 0.5) * 90
                        p.y += (r.next() - 0.5) * 90
                        c.addLine(to: p)
                    }
                    c.setStrokeColor(UIColor(red: 1, green: 0.45 + r.next() * 0.35, blue: 0.05, alpha: 1).cgColor)
                    c.setLineWidth(2 + r.next() * 6)
                    c.strokePath()
                }
            }
        }
    }

    static var holo: UIImage {
        cached("holo") {
            render(CGSize(width: 512, height: 64)) { c, s in
                let cols = stride(from: 0.0, through: 1.0, by: 1.0 / 7).map { UIColor(hue: CGFloat($0), saturation: 0.55, brightness: 1, alpha: 1).cgColor }
                let locs: [CGFloat] = cols.indices.map { CGFloat($0) / CGFloat(cols.count - 1) }
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: locs)!
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: s.width, y: 0), options: [])
            }
        }
    }

    /// Mirror tiles for the disco poop.
    static var disco: UIImage {
        cached("disco") {
            render(CGSize(width: 512, height: 512)) { c, s in
                let n = 24
                let w = s.width / CGFloat(n)
                var r = Rand(state: 99)
                for i in 0..<n {
                    for j in 0..<n {
                        let v = 0.55 + r.next() * 0.45
                        let tint = r.next()
                        let color = tint > 0.9 ? UIColor(hue: CGFloat(r.next()), saturation: 0.5, brightness: CGFloat(v), alpha: 1) : UIColor(white: CGFloat(v), alpha: 1)
                        c.setFillColor(color.cgColor)
                        c.fill(CGRect(x: CGFloat(i) * w + 1, y: CGFloat(j) * w + 1, width: w - 2, height: w - 2))
                    }
                }
            }
        }
    }

    /// Bold stripes (party hat).
    static func stripes(_ a: UIColor, _ b: UIColor) -> UIImage {
        cached("stripes-\(a.description)-\(b.description)") {
            render(CGSize(width: 256, height: 256)) { c, s in
                let n = 8
                for i in 0..<n {
                    c.setFillColor((i % 2 == 0 ? a : b).cgColor)
                    c.fill(CGRect(x: CGFloat(i) * s.width / CGFloat(n), y: 0, width: s.width / CGFloat(n), height: s.height))
                }
            }
        }
    }

    /// Simple cartoon globe: blue ocean with lime blobs.
    static var globe: UIImage {
        cached("globe") {
            render(CGSize(width: 512, height: 256)) { c, s in
                c.setFillColor(UIColor(red: 0.18, green: 0.36, blue: 1, alpha: 1).cgColor)
                c.fill(CGRect(origin: .zero, size: s))
                var r = Rand(state: 1234)
                c.setFillColor(UIColor(red: 0.72, green: 0.96, blue: 0.23, alpha: 1).cgColor)
                for _ in 0..<14 {
                    let cx = r.next() * s.width, cy = 30 + r.next() * (s.height - 60)
                    for _ in 0..<5 {
                        let w = 20 + r.next() * 60, h = 14 + r.next() * 40
                        c.fillEllipse(in: CGRect(x: cx + (r.next() - 0.5) * 50, y: cy + (r.next() - 0.5) * 30, width: w, height: h))
                    }
                }
            }
        }
    }

    /// Clock face for the melting clock.
    static var clockFace: UIImage {
        cached("clock") {
            render(CGSize(width: 256, height: 256)) { c, s in
                c.setFillColor(UIColor(red: 1, green: 0.98, blue: 0.92, alpha: 1).cgColor)
                c.fill(CGRect(origin: .zero, size: s))
                c.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
                let center = CGPoint(x: s.width / 2, y: s.height / 2)
                for i in 0..<12 {
                    let a = Double(i) / 12 * 2 * .pi
                    let p = CGPoint(x: center.x + CGFloat(cos(a)) * 100, y: center.y + CGFloat(sin(a)) * 100)
                    c.fillEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                }
                c.setStrokeColor(UIColor(white: 0.1, alpha: 1).cgColor)
                c.setLineCap(.round)
                c.setLineWidth(10)
                c.move(to: center); c.addLine(to: CGPoint(x: center.x, y: center.y - 70)); c.strokePath()
                c.setLineWidth(7)
                c.move(to: center); c.addLine(to: CGPoint(x: center.x + 80, y: center.y + 10)); c.strokePath()
            }
        }
    }

    /// Checkered flag cloth.
    static var checker: UIImage {
        cached("checker") {
            render(CGSize(width: 256, height: 256)) { c, s in
                let n = 6
                let w = s.width / CGFloat(n)
                for i in 0..<n {
                    for j in 0..<n {
                        c.setFillColor(((i + j) % 2 == 0 ? UIColor(red: 1, green: 0.18, blue: 0.58, alpha: 1) : UIColor.white).cgColor)
                        c.fill(CGRect(x: CGFloat(i) * w, y: CGFloat(j) * w, width: w, height: w))
                    }
                }
            }
        }
    }
}
