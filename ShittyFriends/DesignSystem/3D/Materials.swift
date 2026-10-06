import SceneKit
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Physically based materials for poops, trophies and props.
enum Materials {
    static func pbr(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5, coat: CGFloat = 0, coatRough: CGFloat = 0.05) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if coat > 0 {
            m.clearCoat.contents = coat
            m.clearCoatRoughness.contents = coatRough
        }
        return m
    }

    static func emissive(_ color: UIColor, glow: UIColor? = nil, intensity: CGFloat = 1) -> SCNMaterial {
        let m = pbr(color, rough: 0.4)
        m.emission.contents = glow ?? color
        m.emission.intensity = intensity
        return m
    }

    static var gold: SCNMaterial { pbr(UIColor(hex: 0xFFC94A), metal: 1, rough: 0.16) }
    static var chrome: SCNMaterial { pbr(UIColor(white: 0.96, alpha: 1), metal: 1, rough: 0.04) }
    static var ceramic: SCNMaterial { pbr(UIColor(white: 0.97, alpha: 1), rough: 0.18, coat: 1) }
    static var paper: SCNMaterial { pbr(UIColor(hex: 0xFFFDF6), rough: 0.85) }
    static var ink: SCNMaterial { pbr(UIColor(hex: 0x17121F), rough: 0.3, coat: 0.6) }
    static var eyeWhite: SCNMaterial { pbr(.white, rough: 0.12, coat: 1) }

    static func glass(_ tint: UIColor) -> SCNMaterial {
        let m = pbr(tint, metal: 0, rough: 0.02, coat: 1, coatRough: 0.01)
        m.transparency = 0.55
        m.transparencyMode = .dualLayer
        m.isDoubleSided = false
        m.fresnelExponent = 2
        return m
    }

    static func gem(_ color: UIColor) -> SCNMaterial {
        let m = pbr(color, metal: 0.3, rough: 0.05, coat: 1)
        m.emission.contents = color.withAlphaComponent(0.25)
        return m
    }

    /// Body material for a poop cosmetic.
    static func poop(_ id: CosmeticID) -> SCNMaterial {
        switch id {
        case .classic:
            return pbr(UIColor(hex: 0x7A4A24), rough: 0.42, coat: 0.25)
        case .glossy:
            return pbr(UIColor(hex: 0x8B5228), rough: 0.18, coat: 1, coatRough: 0.02)
        case .softServe:
            return pbr(UIColor(hex: 0xF4D9A8), rough: 0.5, coat: 0.3)
        case .ice:
            let m = glass(UIColor(hex: 0xA9E8FF))
            m.transparency = 0.72
            m.emission.contents = UIColor(hex: 0x1A5A80)
            m.emission.intensity = 0.25
            return m
        case .lava:
            let m = pbr(UIColor(hex: 0x2A1410), rough: 0.7)
            m.emission.contents = Textures.lavaCracks
            m.emission.intensity = 2.2
            return m
        case .gold:
            return gold
        case .chrome:
            return chrome
        case .glass:
            return glass(UIColor(hex: 0xF0E8FF))
        case .galaxy:
            let m = pbr(.white, rough: 0.25, coat: 1)
            m.diffuse.contents = Textures.galaxy
            m.emission.contents = Textures.galaxy
            m.emission.intensity = 0.35
            return m
        case .radioactive:
            let m = pbr(UIColor(hex: 0x6CFF2E), rough: 0.3, coat: 0.8)
            m.emission.contents = UIColor(hex: 0x7DFF3A)
            m.emission.intensity = 1.1
            return m
        case .angel:
            return pbr(UIColor(hex: 0xFFF8F0), metal: 0.15, rough: 0.2, coat: 1)
        case .devil:
            return pbr(UIColor(hex: 0xE0201B), rough: 0.25, coat: 1)
        case .disco:
            let m = pbr(.white, metal: 1, rough: 0.08)
            m.diffuse.contents = Textures.disco
            m.metalness.contents = 1.0
            return m
        case .royal:
            return pbr(UIColor(hex: 0x5B2BB5), metal: 0.25, rough: 0.2, coat: 1)
        case .holographic:
            let m = pbr(.white, metal: 0.85, rough: 0.12, coat: 1)
            m.diffuse.contents = Textures.holo
            m.diffuse.wrapS = .repeat
            m.emission.contents = Textures.holo
            m.emission.intensity = 0.25
            return m
        case .legendary:
            let m = pbr(UIColor(hex: 0xFFC94A), metal: 1, rough: 0.1)
            m.emission.contents = Textures.holo
            m.emission.intensity = 0.55
            return m
        }
    }
}
