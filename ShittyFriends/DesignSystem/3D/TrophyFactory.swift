import SceneKit
import UIKit

/// Glossy collectible objects for achievements and group icons, built from primitives.
/// Every object sits on y = 0 and is roughly 1.0–1.2 units tall.
enum TrophyFactory {
    static func node(_ object: TrophyObject) -> SCNNode {
        switch object {
        case .goldenToilet: return toilet(body: Materials.gold, seat: Materials.gold)
        case .jeweledPaper: return roll(paper: Materials.paper, jewels: true)
        case .crown: return crown(scale: 1)
        case .chromePoop: return PoopFactory.node(.chrome)
        case .meltingClock: return meltingClock()
        case .twinToilets: return twinToilets()
        case .passportPoop: return passportPoop()
        case .flamingThrone: return flamingThrone()
        case .crystalRoll: return roll(paper: Materials.glass(UIColor(hex: 0xE8DCFF)), jewels: false)
        case .partyHat: return partyHat()
        case .globe: return globe()
        case .flag: return flag()
        case .sun: return sun()
        case .moon: return moon()
        }
    }

    // MARK: - Toilet

    static func toilet(body: SCNMaterial = Materials.ceramic, seat: SCNMaterial = Materials.chrome) -> SCNNode {
        let root = SCNNode()
        let base = SCNNode(geometry: SCNCylinder(radius: 0.2, height: 0.3))
        base.geometry?.materials = [body]
        base.position = SCNVector3(0, 0.15, 0.05)
        root.addChildNode(base)
        let bowl = SCNNode(geometry: SCNSphere(radius: 0.38))
        bowl.geometry?.materials = [body]
        bowl.scale = SCNVector3(1, 0.62, 1.2)
        bowl.position = SCNVector3(0, 0.42, 0.08)
        root.addChildNode(bowl)
        let rim = SCNNode(geometry: SCNTorus(ringRadius: 0.34, pipeRadius: 0.06))
        rim.geometry?.materials = [seat]
        rim.scale = SCNVector3(1, 1, 1.2)
        rim.position = SCNVector3(0, 0.62, 0.08)
        root.addChildNode(rim)
        let water = SCNNode(geometry: SCNCylinder(radius: 0.28, height: 0.01))
        water.geometry?.materials = [Materials.glass(UIColor(hex: 0x6FD3FF))]
        water.scale = SCNVector3(1, 1, 1.2)
        water.position = SCNVector3(0, 0.6, 0.08)
        root.addChildNode(water)
        let tank = SCNNode(geometry: SCNBox(width: 0.66, height: 0.5, length: 0.24, chamferRadius: 0.07))
        tank.geometry?.materials = [body]
        tank.position = SCNVector3(0, 0.88, -0.42)
        root.addChildNode(tank)
        let lid = SCNNode(geometry: SCNBox(width: 0.62, height: 0.06, length: 0.7, chamferRadius: 0.03))
        lid.geometry?.materials = [seat]
        lid.position = SCNVector3(0, 0.98, -0.2)
        lid.eulerAngles.x = -1.25
        root.addChildNode(lid)
        let handle = SCNNode(geometry: SCNCapsule(capRadius: 0.025, height: 0.16))
        handle.geometry?.materials = [Materials.chrome]
        handle.eulerAngles.z = .pi / 2
        handle.position = SCNVector3(-0.22, 1.02, -0.29)
        root.addChildNode(handle)
        return root
    }

    static func twinToilets() -> SCNNode {
        let root = SCNNode()
        let a = toilet()
        a.position = SCNVector3(-0.42, 0, 0)
        a.eulerAngles.y = 0.25
        a.scale = SCNVector3(0.75, 0.75, 0.75)
        let b = toilet()
        b.position = SCNVector3(0.42, 0, 0)
        b.eulerAngles.y = -0.25
        b.scale = SCNVector3(0.75, 0.75, 0.75)
        root.addChildNode(a)
        root.addChildNode(b)
        let heart = SCNNode(geometry: SCNSphere(radius: 0.08))
        heart.geometry?.materials = [Materials.gem(UIColor(hex: 0xFF2E93))]
        heart.position = SCNVector3(0, 1.0, 0)
        root.addChildNode(heart)
        return root
    }

    static func flamingThrone() -> SCNNode {
        let root = toilet(body: Materials.gold, seat: Materials.pbr(UIColor(hex: 0xE0201B), rough: 0.2, coat: 1))
        let flameColors: [UInt32] = [0xFF7A1A, 0xFFD02E, 0xFF4436]
        for i in 0..<7 {
            let angle = Double(i) / 7 * 2 * .pi
            let h = 0.35 + 0.15 * Double(i % 3)
            let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.09, height: CGFloat(h)))
            let col = UIColor(hex: flameColors[i % 3])
            let m = Materials.emissive(col, intensity: 1.6)
            m.transparency = 0.85
            cone.geometry?.materials = [m]
            cone.position = SCNVector3(Float(cos(angle) * 0.48), Float(0.18 + h / 2), Float(sin(angle) * 0.48))
            root.addChildNode(cone)
        }
        return root
    }

    // MARK: - Paper

    static func roll(paper: SCNMaterial, jewels: Bool) -> SCNNode {
        let root = SCNNode()
        let outer = SCNNode(geometry: SCNTube(innerRadius: 0.13, outerRadius: 0.38, height: 0.55))
        outer.geometry?.materials = [paper]
        outer.position = SCNVector3(0, 0.38, 0)
        outer.eulerAngles.x = .pi / 2
        root.addChildNode(outer)
        let core = SCNNode(geometry: SCNTube(innerRadius: 0.11, outerRadius: 0.13, height: 0.56))
        core.geometry?.materials = [Materials.pbr(UIColor(hex: 0xC99A5B), rough: 0.9)]
        core.position = outer.position
        core.eulerAngles.x = .pi / 2
        root.addChildNode(core)
        let sheet = SCNNode(geometry: SCNBox(width: 0.5, height: 0.36, length: 0.012, chamferRadius: 0.005))
        sheet.geometry?.materials = [paper]
        sheet.position = SCNVector3(0, 0.18, 0.37)
        root.addChildNode(sheet)
        if jewels {
            let colors: [UInt32] = [0xFF2E93, 0x2F5BFF, 0x12D9C4, 0xFFD02E, 0x8A4DFF, 0xB8F43A]
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let g = SCNNode(geometry: SCNSphere(radius: 0.045))
                g.geometry?.materials = [Materials.gem(UIColor(hex: colors[i % colors.count]))]
                g.position = SCNVector3(Float(cos(a) * 0.385), Float(0.38 + sin(a) * 0.385), 0.27)
                root.addChildNode(g)
            }
            let band = SCNNode(geometry: SCNTorus(ringRadius: 0.385, pipeRadius: 0.02))
            band.geometry?.materials = [Materials.gold]
            band.position = SCNVector3(0, 0.38, 0.27)
            band.eulerAngles.x = .pi / 2
            root.addChildNode(band)
        }
        return root
    }

    // MARK: - Crown

    static func crown(scale: Float) -> SCNNode {
        let root = SCNNode()
        let ring = SCNNode(geometry: SCNTube(innerRadius: 0.36, outerRadius: 0.42, height: 0.22))
        ring.geometry?.materials = [Materials.gold]
        ring.position = SCNVector3(0, 0.11, 0)
        root.addChildNode(ring)
        let gems: [UInt32] = [0xFF2E93, 0x2F5BFF, 0x12D9C4, 0x8A4DFF, 0xFF4436]
        for i in 0..<5 {
            let a = Double(i) / 5 * 2 * .pi
            let spike = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.11, height: 0.32))
            spike.geometry?.materials = [Materials.gold]
            spike.position = SCNVector3(Float(cos(a) * 0.39), 0.36, Float(sin(a) * 0.39))
            root.addChildNode(spike)
            let ball = SCNNode(geometry: SCNSphere(radius: 0.05))
            ball.geometry?.materials = [Materials.gold]
            ball.position = SCNVector3(Float(cos(a) * 0.39), 0.53, Float(sin(a) * 0.39))
            root.addChildNode(ball)
            let gem = SCNNode(geometry: SCNSphere(radius: 0.055))
            gem.geometry?.materials = [Materials.gem(UIColor(hex: gems[i]))]
            gem.position = SCNVector3(Float(cos(a + .pi / 5) * 0.43), 0.11, Float(sin(a + .pi / 5) * 0.43))
            root.addChildNode(gem)
        }
        root.scale = SCNVector3(scale, scale, scale)
        return root
    }

    // MARK: - Misc

    static func meltingClock() -> SCNNode {
        let root = SCNNode()
        let face = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.06))
        let m = Materials.pbr(.white, rough: 0.3, coat: 1)
        m.diffuse.contents = Textures.clockFace
        let rimMat = Materials.gold
        face.geometry?.materials = [rimMat, m, rimMat]
        face.position = SCNVector3(0, 0.62, 0)
        face.eulerAngles = SCNVector3(Float.pi / 2 - 0.25, 0, 0.2)
        face.scale = SCNVector3(1, 1, 1.35)
        root.addChildNode(face)
        // Drips
        for (x, h) in [(-0.22, 0.32), (0.05, 0.48), (0.26, 0.24)] {
            let drip = SCNNode(geometry: SCNCapsule(capRadius: 0.07, height: CGFloat(h)))
            drip.geometry?.materials = [Materials.gold]
            drip.position = SCNVector3(Float(x), Float(0.46 - h / 2), 0.1)
            root.addChildNode(drip)
        }
        let stand = SCNNode(geometry: SCNBox(width: 0.7, height: 0.08, length: 0.4, chamferRadius: 0.03))
        stand.geometry?.materials = [Materials.ink]
        stand.position = SCNVector3(0, 0.04, 0)
        root.addChildNode(stand)
        return root
    }

    static func passportPoop() -> SCNNode {
        let root = SCNNode()
        let book = SCNNode(geometry: SCNBox(width: 0.72, height: 0.1, length: 0.95, chamferRadius: 0.04))
        book.geometry?.materials = [Materials.pbr(UIColor(hex: 0x1D2A6B), rough: 0.6, coat: 0.3)]
        book.position = SCNVector3(0, 0.05, 0)
        book.eulerAngles.y = 0.3
        root.addChildNode(book)
        let emblem = SCNNode(geometry: SCNCylinder(radius: 0.16, height: 0.012))
        emblem.geometry?.materials = [Materials.gold]
        emblem.position = SCNVector3(0, 0.106, 0)
        book.addChildNode(emblem)
        let poop = PoopFactory.node(.classic, lowPoly: true)
        poop.scale = SCNVector3(0.62, 0.62, 0.62)
        poop.position = SCNVector3(0, 0.1, 0.05)
        root.addChildNode(poop)
        return root
    }

    static func partyHat() -> SCNNode {
        let root = SCNNode()
        let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.36, height: 0.95))
        let m = Materials.pbr(.white, rough: 0.35, coat: 0.8)
        m.diffuse.contents = Textures.stripes(UIColor(hex: 0xFF2E93), UIColor(hex: 0xFFD02E))
        cone.geometry?.materials = [m]
        cone.position = SCNVector3(0, 0.48, 0)
        root.addChildNode(cone)
        let pom = SCNNode(geometry: SCNSphere(radius: 0.11))
        pom.geometry?.materials = [Materials.pbr(UIColor(hex: 0x12D9C4), rough: 0.8)]
        pom.position = SCNVector3(0, 0.98, 0)
        root.addChildNode(pom)
        return root
    }

    static func globe() -> SCNNode {
        let root = SCNNode()
        let ball = SCNNode(geometry: SCNSphere(radius: 0.4))
        let m = Materials.pbr(.white, rough: 0.25, coat: 1)
        m.diffuse.contents = Textures.globe
        ball.geometry?.materials = [m]
        ball.position = SCNVector3(0, 0.68, 0)
        ball.eulerAngles.z = 0.4
        root.addChildNode(ball)
        let arc = SCNNode(geometry: SCNTorus(ringRadius: 0.47, pipeRadius: 0.025))
        arc.geometry?.materials = [Materials.gold]
        arc.position = ball.position
        arc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0.4)
        root.addChildNode(arc)
        let stem = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.22))
        stem.geometry?.materials = [Materials.gold]
        stem.position = SCNVector3(0, 0.15, 0)
        root.addChildNode(stem)
        let base = SCNNode(geometry: SCNCylinder(radius: 0.26, height: 0.06))
        base.geometry?.materials = [Materials.ink]
        base.position = SCNVector3(0, 0.03, 0)
        root.addChildNode(base)
        return root
    }

    static func flag() -> SCNNode {
        let root = SCNNode()
        let pole = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 1.15))
        pole.geometry?.materials = [Materials.chrome]
        pole.position = SCNVector3(-0.3, 0.575, 0)
        root.addChildNode(pole)
        let cloth = SCNNode(geometry: SCNBox(width: 0.62, height: 0.42, length: 0.02, chamferRadius: 0.01))
        let m = Materials.pbr(.white, rough: 0.7)
        m.diffuse.contents = Textures.checker
        cloth.geometry?.materials = [m]
        cloth.position = SCNVector3(0.02, 0.92, 0)
        cloth.eulerAngles.y = -0.2
        root.addChildNode(cloth)
        let mound = SCNNode(geometry: SCNSphere(radius: 0.3))
        mound.geometry?.materials = [Materials.poop(.classic)]
        mound.scale = SCNVector3(1.2, 0.4, 1.0)
        mound.position = SCNVector3(-0.25, 0.04, 0)
        root.addChildNode(mound)
        return root
    }

    static func sun() -> SCNNode {
        let root = SCNNode()
        let core = SCNNode(geometry: SCNSphere(radius: 0.34))
        core.geometry?.materials = [Materials.emissive(UIColor(hex: 0xFFD02E), glow: UIColor(hex: 0xFFB800), intensity: 0.9)]
        core.position = SCNVector3(0, 0.6, 0)
        root.addChildNode(core)
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi
            let ray = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.07, height: 0.2))
            ray.geometry?.materials = [Materials.emissive(UIColor(hex: 0xFF7A1A), intensity: 0.8)]
            ray.position = SCNVector3(Float(cos(a) * 0.48), Float(0.6 + sin(a) * 0.48), 0)
            ray.eulerAngles.z = Float(a - .pi / 2)
            root.addChildNode(ray)
        }
        return root
    }

    static func moon() -> SCNNode {
        let root = SCNNode()
        let path = UIBezierPath()
        path.addArc(withCenter: .zero, radius: 0.45, startAngle: .pi * 0.5, endAngle: .pi * 1.5, clockwise: true)
        path.addQuadCurve(to: CGPoint(x: 0, y: 0.45), controlPoint: CGPoint(x: -0.28, y: 0))
        path.close()
        path.flatness = 0.002
        let shape = SCNShape(path: path, extrusionDepth: 0.22)
        shape.chamferRadius = 0.05
        shape.materials = [Materials.emissive(UIColor(hex: 0xFFE27A), glow: UIColor(hex: 0x8A6B00), intensity: 0.4)]
        let crescent = SCNNode(geometry: shape)
        crescent.position = SCNVector3(0.08, 0.6, 0)
        root.addChildNode(crescent)
        for (x, y) in [(0.25, 0.95), (0.38, 0.52), (-0.38, 1.0)] {
            let star = SCNNode(geometry: SCNSphere(radius: 0.04))
            star.geometry?.materials = [Materials.emissive(.white, intensity: 1.5)]
            star.position = SCNVector3(Float(x), Float(y), 0)
            root.addChildNode(star)
        }
        return root
    }

    /// Group icons (GroupObject) reuse trophies and props where possible.
    static func node(_ object: GroupObject) -> SCNNode {
        switch object {
        case .toilet: return toilet()
        case .roll: return roll(paper: Materials.paper, jewels: false)
        case .crown: return crown(scale: 1)
        case .poop: return PoopFactory.node(.glossy)
        case .plunger:
            let root = SCNNode()
            let cup = SCNNode(geometry: SCNSphere(radius: 0.3))
            cup.geometry?.materials = [Materials.pbr(UIColor(hex: 0xE0201B), rough: 0.3, coat: 1)]
            cup.scale = SCNVector3(1, 0.6, 1)
            cup.position = SCNVector3(0, 0.15, 0)
            root.addChildNode(cup)
            let stick = SCNNode(geometry: SCNCylinder(radius: 0.045, height: 0.85))
            stick.geometry?.materials = [Materials.pbr(UIColor(hex: 0xC99A5B), rough: 0.6)]
            stick.position = SCNVector3(0, 0.62, 0)
            root.addChildNode(stick)
            return root
        case .rubberDuck:
            let root = SCNNode()
            let yellow = Materials.pbr(UIColor(hex: 0xFFD02E), rough: 0.25, coat: 1)
            let body = SCNNode(geometry: SCNSphere(radius: 0.36))
            body.geometry?.materials = [yellow]
            body.scale = SCNVector3(1.15, 0.8, 0.95)
            body.position = SCNVector3(0, 0.3, 0)
            root.addChildNode(body)
            let head = SCNNode(geometry: SCNSphere(radius: 0.22))
            head.geometry?.materials = [yellow]
            head.position = SCNVector3(0.18, 0.72, 0)
            root.addChildNode(head)
            let beak = SCNNode(geometry: SCNSphere(radius: 0.09))
            beak.geometry?.materials = [Materials.pbr(UIColor(hex: 0xFF7A1A), rough: 0.3, coat: 1)]
            beak.scale = SCNVector3(1.6, 0.6, 1)
            beak.position = SCNVector3(0.42, 0.68, 0)
            root.addChildNode(beak)
            for z in [-0.12, 0.12] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.035))
                eye.geometry?.materials = [Materials.ink]
                eye.position = SCNVector3(0.3, 0.8, Float(z))
                root.addChildNode(eye)
            }
            return root
        case .rocket:
            let root = SCNNode()
            let body = SCNNode(geometry: SCNCapsule(capRadius: 0.2, height: 0.9))
            body.geometry?.materials = [Materials.chrome]
            body.position = SCNVector3(0, 0.6, 0)
            root.addChildNode(body)
            let window = SCNNode(geometry: SCNSphere(radius: 0.09))
            window.geometry?.materials = [Materials.glass(UIColor(hex: 0x45C2FF))]
            window.position = SCNVector3(0, 0.75, 0.17)
            root.addChildNode(window)
            for i in 0..<3 {
                let a = Double(i) / 3 * 2 * .pi
                let fin = SCNNode(geometry: SCNBox(width: 0.04, height: 0.3, length: 0.22, chamferRadius: 0.01))
                fin.geometry?.materials = [Materials.pbr(UIColor(hex: 0xFF4436), rough: 0.3, coat: 1)]
                fin.position = SCNVector3(Float(cos(a) * 0.22), 0.2, Float(sin(a) * 0.22))
                fin.eulerAngles.y = Float(-a)
                root.addChildNode(fin)
            }
            let flame = SCNNode(geometry: SCNCone(topRadius: 0.12, bottomRadius: 0, height: 0.3))
            flame.geometry?.materials = [Materials.emissive(UIColor(hex: 0xFF7A1A), intensity: 1.5)]
            flame.position = SCNVector3(0, -0.02, 0)
            root.addChildNode(flame)
            return root
        case .pizza:
            let root = SCNNode()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: 0.6))
            path.addLine(to: CGPoint(x: -0.42, y: -0.4))
            path.addQuadCurve(to: CGPoint(x: 0.42, y: -0.4), controlPoint: CGPoint(x: 0, y: -0.55))
            path.close()
            let slice = SCNShape(path: path, extrusionDepth: 0.08)
            slice.chamferRadius = 0.03
            slice.materials = [Materials.pbr(UIColor(hex: 0xFFD02E), rough: 0.6)]
            let node = SCNNode(geometry: slice)
            node.position = SCNVector3(0, 0.55, 0)
            root.addChildNode(node)
            for (x, y) in [(0.0, 0.25), (-0.15, -0.12), (0.16, -0.18)] {
                let pep = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 0.02))
                pep.geometry?.materials = [Materials.pbr(UIColor(hex: 0xE0201B), rough: 0.4)]
                pep.eulerAngles.x = .pi / 2
                pep.position = SCNVector3(Float(x), Float(y), 0.05)
                node.addChildNode(pep)
            }
            return root
        case .skull:
            let root = SCNNode()
            let bone = Materials.pbr(UIColor(hex: 0xFFF6E0), rough: 0.35, coat: 0.6)
            let head = SCNNode(geometry: SCNSphere(radius: 0.38))
            head.geometry?.materials = [bone]
            head.position = SCNVector3(0, 0.62, 0)
            root.addChildNode(head)
            let jaw = SCNNode(geometry: SCNBox(width: 0.42, height: 0.22, length: 0.34, chamferRadius: 0.08))
            jaw.geometry?.materials = [bone]
            jaw.position = SCNVector3(0, 0.26, 0.08)
            root.addChildNode(jaw)
            for x in [-0.14, 0.14] {
                let socket = SCNNode(geometry: SCNSphere(radius: 0.1))
                socket.geometry?.materials = [Materials.ink]
                socket.position = SCNVector3(Float(x), 0.62, 0.3)
                root.addChildNode(socket)
            }
            return root
        case .star:
            let root = SCNNode()
            let path = UIBezierPath()
            for i in 0..<10 {
                let r: CGFloat = i % 2 == 0 ? 0.5 : 0.22
                let a = CGFloat(i) / 10 * 2 * .pi + .pi / 2
                let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.close()
            let star = SCNShape(path: path, extrusionDepth: 0.16)
            star.chamferRadius = 0.04
            star.materials = [Materials.gold]
            let node = SCNNode(geometry: star)
            node.position = SCNVector3(0, 0.55, 0)
            root.addChildNode(node)
            return root
        }
    }
}
