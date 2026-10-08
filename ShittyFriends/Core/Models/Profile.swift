import Foundation

/// Stylized avatar built from preset parts. No photos: keeps moderation trivial
/// and fits the visual language. Fully describable in a handful of small fields.
public struct AvatarSpec: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case round, squircle, blob, bean, tall }
    public enum Eyes: String, Codable, CaseIterable, Sendable { case dots, happy, wide, sleepy, wink, stars, angry }
    public enum Mouth: String, Codable, CaseIterable, Sendable { case smile, grin, flat, oh, tongue, smirk, teeth }
    public enum Accessory: String, Codable, CaseIterable, Sendable { case none, cap, crown, headphones, glasses, shades, bow, beanie, halo, horns }

    /// Face tones: a mix of human and absurd colors.
    public static let tones: [UInt32] = [0xFFE0C2, 0xF6C49B, 0xD99B6C, 0xA86B45, 0x6E4329, 0x3E2618, 0xB8F43A, 0x9AD7FF, 0xFFB3E0, 0xC9A7FF]

    public var shape: Shape
    public var tone: Int
    public var eyes: Eyes
    public var mouth: Mouth
    public var accessory: Accessory

    public init(shape: Shape = .round, tone: Int = 0, eyes: Eyes = .dots, mouth: Mouth = .smile, accessory: Accessory = .none) {
        self.shape = shape
        self.tone = tone
        self.eyes = eyes
        self.mouth = mouth
        self.accessory = accessory
    }

    public var toneHex: UInt32 { AvatarSpec.tones[max(0, min(tone, AvatarSpec.tones.count - 1))] }

    public static func random() -> AvatarSpec {
        AvatarSpec(
            shape: Shape.allCases.randomElement() ?? .round,
            tone: Int.random(in: 0..<tones.count),
            eyes: Eyes.allCases.randomElement() ?? .dots,
            mouth: Mouth.allCases.randomElement() ?? .smile,
            accessory: Accessory.allCases.randomElement() ?? .none
        )
    }

    /// Compact string form used in invite links ("r.3.dots.smile.cap").
    public var compact: String { [shape.rawValue, String(tone), eyes.rawValue, mouth.rawValue, accessory.rawValue].joined(separator: ".") }

    public init?(compact: String) {
        let p = compact.split(separator: ".").map(String.init)
        guard p.count == 5,
              let s = Shape(rawValue: p[0]), let t = Int(p[1]),
              let e = Eyes(rawValue: p[2]), let m = Mouth(rawValue: p[3]),
              let a = Accessory(rawValue: p[4]) else { return nil }
        self.init(shape: s, tone: t, eyes: e, mouth: m, accessory: a)
    }
}

/// Public-to-friends identity. Lives in the user's shared "Me" zone.
public struct UserProfile: Codable, Hashable, Sendable {
    public var handle: String
    public var avatar: AvatarSpec
    public var color: IdentityColor
    public var equippedCosmetic: CosmeticID
    public var equippedPinShine: PinShineID
    public var pinShines: [PinShineID: PinShineUnlock]
    /// Half-points earned on poops that were deleted afterwards. Deleting history never takes
    /// points (or already-bought cosmetics) away.
    public var bankedHalfPoints: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(handle: String, avatar: AvatarSpec, color: IdentityColor, equippedCosmetic: CosmeticID = .classic, createdAt: Date = Date(), updatedAt: Date = Date(), equippedPinShine: PinShineID = .classicWhite, pinShines: [PinShineID: PinShineUnlock] = [:], bankedHalfPoints: Int = 0) {
        self.handle = handle
        self.avatar = avatar
        self.color = color
        self.equippedCosmetic = equippedCosmetic
        self.equippedPinShine = equippedPinShine
        self.pinShines = pinShines
        self.bankedHalfPoints = bankedHalfPoints
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case handle, avatar, color, equippedCosmetic, equippedPinShine, pinShines, bankedHalfPoints, createdAt, updatedAt
    }

    /// Older local backups and CloudKit profiles have no shine or banked-points fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        avatar = try c.decode(AvatarSpec.self, forKey: .avatar)
        color = try c.decode(IdentityColor.self, forKey: .color)
        equippedCosmetic = (try? c.decode(CosmeticID.self, forKey: .equippedCosmetic)) ?? .classic
        equippedPinShine = (try? c.decode(PinShineID.self, forKey: .equippedPinShine)) ?? .classicWhite
        pinShines = (try? c.decode([PinShineID: PinShineUnlock].self, forKey: .pinShines)) ?? [:]
        bankedHalfPoints = (try? c.decode(Int.self, forKey: .bankedHalfPoints)) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public static let placeholder = UserProfile(handle: "you", avatar: AvatarSpec(), color: .lime)
}

/// Lightweight identity used in lists, sessions and group member rows.
public struct PersonRef: Codable, Hashable, Sendable, Identifiable {
    public var id: UserID
    public var handle: String
    public var avatar: AvatarSpec
    public var color: IdentityColor
    public var cosmetic: CosmeticID
    public var pinShine: PinShineID

    public init(id: UserID, handle: String, avatar: AvatarSpec, color: IdentityColor, cosmetic: CosmeticID = .classic, pinShine: PinShineID = .classicWhite) {
        self.id = id
        self.handle = handle
        self.avatar = avatar
        self.color = color
        self.cosmetic = cosmetic
        self.pinShine = pinShine
    }

    public init(id: UserID, profile: UserProfile) {
        self.init(id: id, handle: profile.handle, avatar: profile.avatar, color: profile.color, cosmetic: profile.equippedCosmetic, pinShine: profile.equippedPinShine)
    }

    private enum CodingKeys: String, CodingKey { case id, handle, avatar, color, cosmetic, pinShine }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UserID.self, forKey: .id)
        handle = try c.decode(String.self, forKey: .handle)
        avatar = try c.decode(AvatarSpec.self, forKey: .avatar)
        color = try c.decode(IdentityColor.self, forKey: .color)
        cosmetic = (try? c.decode(CosmeticID.self, forKey: .cosmetic)) ?? .classic
        pinShine = (try? c.decode(PinShineID.self, forKey: .pinShine)) ?? .classicWhite
    }
}
