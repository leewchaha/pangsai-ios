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

    /// Price in whole points. Taps are uncapped (1 point each, +1 on a critical), so prices carry the
    /// pacing: an engaged user earns very roughly 150–250 points a day, a first common takes a few
    /// days, a rare a few weeks, and Legendary over a year of normal play (months for heavy tappers).
    /// Already-bought items keep the cost they were bought at (`CosmeticUnlock.cost`).
    public var price: Int {
        switch self {
        case .classic: return 0
        case .glossy: return 800
        case .softServe: return 1_600
        case .ice: return 2_800
        case .lava: return 4_500
        case .gold: return 6_500
        case .chrome: return 9_000
        case .glass: return 12_000
        case .galaxy: return 16_000
        case .radioactive: return 21_000
        case .angel: return 27_000
        case .devil: return 27_000
        case .disco: return 35_000
        case .royal: return 45_000
        case .holographic: return 60_000
        case .legendary: return 100_000
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


/// Visual effects attached to the *selected* map pin only; never animated while idle.
public enum PinShineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case classicWhite, golden, electric, neonOrbit, aurora, prismatic

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .classicWhite: return "Classic White"
        case .golden: return "Golden Shine"
        case .electric: return "Electric"
        case .neonOrbit: return "Neon Orbit"
        case .aurora: return "Aurora"
        case .prismatic: return "Prismatic"
        }
    }
    public var tagline: String {
        switch self {
        case .classicWhite: return "A clean white radiance."
        case .golden: return "Sunlit golden rays."
        case .electric: return "A spark in the map."
        case .neonOrbit: return "Orbiting neon light."
        case .aurora: return "The northern lights. Sort of."
        case .prismatic: return "Every color, very briefly."
        }
    }

    /// Same pacing as poop cosmetics (shines share the balance).
    public var price: Int {
        switch self {
        case .classicWhite: return 0
        case .golden: return 5_000
        case .electric: return 12_000
        case .neonOrbit: return 25_000
        case .aurora: return 40_000
        case .prismatic: return 70_000
        }
    }
}

/// Purchases are part of the profile record (one document), so a purchase never needs a separate write.
public struct PinShineUnlock: Codable, Hashable, Sendable {
    public var id: PinShineID
    public var unlockedAt: Date
    public var cost: Int

    public init(id: PinShineID, unlockedAt: Date = Date(), cost: Int) {
        self.id = id
        self.unlockedAt = unlockedAt
        self.cost = cost
    }
}
