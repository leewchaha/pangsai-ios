import Foundation

public enum Rarity: String, Codable, CaseIterable, Sendable, Comparable {
    case common, rare, epic, legendary

    public var displayName: String { rawValue.uppercased() }

    private var order: Int {
        switch self { case .common: return 0; case .rare: return 1; case .epic: return 2; case .legendary: return 3 }
    }

    public static func < (lhs: Rarity, rhs: Rarity) -> Bool { lhs.order < rhs.order }
}

/// Collectible poop styles. Bought with points earned by tapping during timed sessions.
public enum CosmeticID: String, Codable, CaseIterable, Sendable, Identifiable {
    case classic, glossy, softServe, ice, lava, gold, chrome, glass, galaxy, radioactive, angel, devil, disco, royal, holographic, legendary

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic Poop"
        case .glossy: return "Glossy Poop"
        case .softServe: return "Soft-Serve Poop"
        case .ice: return "Ice Poop"
        case .lava: return "Lava Poop"
        case .gold: return "Golden Poop"
        case .chrome: return "Chrome Poop"
        case .glass: return "Crystal Poop"
        case .galaxy: return "Galaxy Poop"
        case .radioactive: return "Radioactive Poop"
        case .angel: return "Angel Poop"
        case .devil: return "Devil Poop"
        case .disco: return "Disco Poop"
        case .royal: return "Royal Poop"
        case .holographic: return "Holographic Poop"
        case .legendary: return "Legendary Poop"
        }
    }

    /// Deadpan one-liner shown on unlock.
    public var tagline: String {
        switch self {
        case .classic: return "The original. Unbothered."
        case .glossy: return "Freshly polished. Somehow."
        case .softServe: return "Not dessert. Please."
        case .ice: return "Cool under pressure."
        case .lava: return "Handle with oven mitts."
        case .gold: return "Unnecessarily expensive looking."
        case .chrome: return "You can see yourself in it. Don't."
        case .glass: return "Fragile. Like your schedule."
        case .galaxy: return "Contains multitudes."
        case .radioactive: return "Glows in the dark. Concerning."
        case .angel: return "Blessed."
        case .devil: return "Cursed. Respectfully."
        case .disco: return "Saturday night fever."
        case .royal: return "Bow."
        case .holographic: return "Changes color when judged."
        case .legendary: return "History will remember this."
        }
    }

    public var rarity: Rarity {
        switch self {
        case .classic, .glossy, .softServe, .ice: return .common
        case .lava, .gold, .chrome, .glass: return .rare
        case .galaxy, .radioactive, .angel, .devil: return .epic
        case .disco, .royal, .holographic, .legendary: return .legendary
        }
    }

    /// Price in whole points.
    public var price: Int {
        switch self {
        case .classic: return 0
        case .glossy: return 25
        case .softServe: return 50
        case .ice: return 80
        case .lava: return 120
        case .gold: return 170
        case .chrome: return 230
        case .glass: return 300
        case .galaxy: return 380
        case .radioactive: return 460
        case .angel: return 550
        case .devil: return 550
        case .disco: return 700
        case .royal: return 850
        case .holographic: return 1000
        case .legendary: return 1400
        }
    }

    public var isAnimated: Bool { self == .legendary || self == .disco || self == .holographic || self == .radioactive }
}

public struct CosmeticUnlock: Codable, Hashable, Sendable, Identifiable {
    public var id: CosmeticID
    public var unlockedAt: Date
    /// Whole points spent.
    public var cost: Int
    public var source: String

    public init(id: CosmeticID, unlockedAt: Date = Date(), cost: Int, source: String = "points") {
        self.id = id
        self.unlockedAt = unlockedAt
        self.cost = cost
        self.source = source
    }
}

/// Preset live reactions (no free text chat in v1).
public enum ReactionKind: String, Codable, CaseIterable, Sendable {
    case laugh, skull, fire, salute, handshake, crown, poop

    public var emoji: String {
        switch self {
        case .laugh: return "😂"
        case .skull: return "💀"
        case .fire: return "🔥"
        case .salute: return "🫡"
        case .handshake: return "🤝"
        case .crown: return "👑"
        case .poop: return "💩"
        }
    }
}
