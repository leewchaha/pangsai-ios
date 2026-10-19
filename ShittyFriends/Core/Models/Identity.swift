import Foundation

/// Firebase Auth user id of a person (stable per account, whichever sign-in provider was used).
/// Before anyone is signed in the local user is identified by `UserID.localMe`.
public typealias UserID = String

public extension UserID {
    static let localMe: UserID = "__me__"
}

/// Random opaque tokens (invite tokens, group join codes). Never derived from identity; safe to rotate.
public enum TokenFactory {
    /// 22-char URL-safe random token (~128 bits).
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncodedString()
    }

    /// 32 random bytes for symmetric keys.
    public static func makeKeyData() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes)
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}

/// Strong identity colors. Every person and group gets one.
public enum IdentityColor: String, Codable, CaseIterable, Sendable, Hashable {
    case lime, electric, hotPink, violet, tangerine, aqua, sun, tomato, mint, sky, grape, bubblegum

    public var hex: UInt32 {
        switch self {
        case .lime: return 0xB8F43A
        case .electric: return 0x2F5BFF
        case .hotPink: return 0xFF2E93
        case .violet: return 0x8A4DFF
        case .tangerine: return 0xFF7A1A
        case .aqua: return 0x12D9C4
        case .sun: return 0xFFD02E
        case .tomato: return 0xFF4436
        case .mint: return 0x5BF2A0
        case .sky: return 0x45C2FF
        case .grape: return 0x5B2BB5
        case .bubblegum: return 0xFF8FD1
        }
    }

    public var displayName: String {
        switch self {
        case .lime: return "Radioactive Lime"
        case .electric: return "Electric Blue"
        case .hotPink: return "Hot Pink"
        case .violet: return "Violet"
        case .tangerine: return "Tangerine"
        case .aqua: return "Aqua"
        case .sun: return "Sun"
        case .tomato: return "Tomato"
        case .mint: return "Mint"
        case .sky: return "Sky"
        case .grape: return "Grape"
        case .bubblegum: return "Bubblegum"
        }
    }

    /// Whether dark ink (vs white) reads better on top of this color.
    public var prefersDarkInk: Bool {
        switch self {
        case .electric, .violet, .grape, .tomato, .hotPink: return false
        default: return true
        }
    }

    public static func random() -> IdentityColor { allCases.randomElement() ?? .lime }

    /// Deterministic fallback color for an id (used when a profile is not loaded yet).
    public static func stable(for id: String) -> IdentityColor {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return allCases[Int(hash % UInt64(allCases.count))]
    }
}
