import Foundation

/// Everything that belongs to me. Persisted locally; most of it also syncs to my iCloud.
public struct MyState: Codable, Hashable, Sendable {
    public var userID: UserID?
    public var onboarded: Bool
    public var ageConfirmed: Bool
    public var profile: UserProfile?
    public var events: [UUID: PoopEvent]
    public var achievements: [AchievementID: AchievementUnlock]
    public var cosmetics: [CosmeticID: CosmeticUnlock]
    public var settings: AppSettings
    public var friendLinks: [UUID: FriendLink]
    public var groupLinks: [UUID: GroupLink]
    public var invites: [String: OutgoingInvite]
    public var spaceLinks: [ZoneRef: SpaceLink]
    /// Device-local: incoming friend requests awaiting my decision.
    public var requests: [String: IncomingFriendRequest]
    /// Device-local: PWM sessions confirmed to have had 2+ people pooping (achievement progress).
    public var confirmedSocialSessions: Set<UUID>
    /// Device-local: archive of finished PWM sessions for export (session zones get cleaned up).
    public var pwmArchive: [UUID: PWMArchiveEntry]

    public init() {
        userID = nil
        onboarded = false
        ageConfirmed = false
        profile = nil
        events = [:]
        achievements = [:]
        cosmetics = [:]
        settings = AppSettings()
        friendLinks = [:]
        groupLinks = [:]
        invites = [:]
        spaceLinks = [:]
        requests = [:]
        confirmedSocialSessions = []
        pwmArchive = [:]
    }

    enum CodingKeys: String, CodingKey {
        case userID, onboarded, ageConfirmed, profile, events, achievements, cosmetics, settings, friendLinks, groupLinks, invites, spaceLinks, requests, confirmedSocialSessions, pwmArchive
    }

    /// Tolerant decoding: unknown/missing fields fall back to defaults so app updates never wipe local data.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MyState()
        userID = (try? c.decodeIfPresent(UserID.self, forKey: .userID)) ?? d.userID
        onboarded = (try? c.decodeIfPresent(Bool.self, forKey: .onboarded)) ?? d.onboarded
        ageConfirmed = (try? c.decodeIfPresent(Bool.self, forKey: .ageConfirmed)) ?? d.ageConfirmed
        profile = (try? c.decodeIfPresent(UserProfile.self, forKey: .profile)) ?? d.profile
        events = (try? c.decodeIfPresent([UUID: PoopEvent].self, forKey: .events)) ?? d.events
        achievements = (try? c.decodeIfPresent([AchievementID: AchievementUnlock].self, forKey: .achievements)) ?? d.achievements
        cosmetics = (try? c.decodeIfPresent([CosmeticID: CosmeticUnlock].self, forKey: .cosmetics)) ?? d.cosmetics
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? d.settings
        friendLinks = (try? c.decodeIfPresent([UUID: FriendLink].self, forKey: .friendLinks)) ?? d.friendLinks
        groupLinks = (try? c.decodeIfPresent([UUID: GroupLink].self, forKey: .groupLinks)) ?? d.groupLinks
        invites = (try? c.decodeIfPresent([String: OutgoingInvite].self, forKey: .invites)) ?? d.invites
        spaceLinks = (try? c.decodeIfPresent([ZoneRef: SpaceLink].self, forKey: .spaceLinks)) ?? d.spaceLinks
        requests = (try? c.decodeIfPresent([String: IncomingFriendRequest].self, forKey: .requests)) ?? d.requests
        confirmedSocialSessions = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .confirmedSocialSessions)) ?? d.confirmedSocialSessions
        pwmArchive = (try? c.decodeIfPresent([UUID: PWMArchiveEntry].self, forKey: .pwmArchive)) ?? d.pwmArchive
    }
}

/// What I keep about a Poop With Me session after its zone is cleaned up (for history + export).
public struct PWMArchiveEntry: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var creatorID: UserID
    public var groupID: UUID?
    public var createdAt: Date
    public var participants: [PersonRef]

    public init(sessionID: UUID, creatorID: UserID, groupID: UUID?, createdAt: Date, participants: [PersonRef]) {
        self.sessionID = sessionID
        self.creatorID = creatorID
        self.groupID = groupID
        self.createdAt = createdAt
        self.participants = participants
    }
}

/// Read caches of other people's data. Safe to drop: it re-syncs from CloudKit.
public struct CacheState: Codable, Hashable, Sendable {
    public var friends: [UserID: FriendCache]
    public var zones: [ZoneRef: ZoneCache]

    public init() {
        friends = [:]
        zones = [:]
    }
}
