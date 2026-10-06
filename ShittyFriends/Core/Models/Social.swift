import Foundation

/// Identifies a CloudKit record zone independently of CloudKit types.
/// `ownerName == ZoneRef.currentUser` means the zone lives in my private database.
public struct ZoneRef: Codable, Hashable, Sendable, CustomStringConvertible {
    /// Matches CloudKit's `CKCurrentUserDefaultName`.
    public static let currentUser = "__defaultOwner__"

    public var ownerName: String
    public var zoneName: String

    public init(ownerName: String, zoneName: String) {
        self.ownerName = ownerName
        self.zoneName = zoneName
    }

    public var isMine: Bool { ownerName == ZoneRef.currentUser }
    public var description: String { "\(zoneName)@\(ownerName)" }

    public static let me = ZoneRef(ownerName: currentUser, zoneName: ZoneNames.me)
    public static let privateZone = ZoneRef(ownerName: currentUser, zoneName: ZoneNames.private)
}

public enum ZoneNames {
    /// Shared read-only with full friends: profile, entire poop history, achievements, cosmetics.
    public static let me = "Me"
    /// Never shared: settings, friend links, group links, invites.
    public static let `private` = "Private"
    public static let groupPrefix = "G-"
    public static let sessionPrefix = "S-"

    public static func group(_ id: UUID) -> String { groupPrefix + id.uuidString }
    public static func session(_ id: UUID) -> String { sessionPrefix + id.uuidString }

    public static func groupID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(groupPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(groupPrefix.count)))
    }
}

// MARK: - Notifications preferences

public enum FriendNotifyLevel: String, Codable, CaseIterable, Sendable {
    case every, pwmOnly, off

    public var title: String {
        switch self {
        case .every: return "Every poop"
        case .pwmOnly: return "Poop With Me only"
        case .off: return "Off"
        }
    }
}

public enum GroupNotifyLevel: String, Codable, CaseIterable, Sendable {
    case all, pwmAndParties, highlightsOnly, off

    public var title: String {
        switch self {
        case .all: return "All activity"
        case .pwmAndParties: return "Poop With Me / Parties only"
        case .highlightsOnly: return "Highlights only"
        case .off: return "Off"
        }
    }
}

// MARK: - Friends

public enum FriendLinkStatus: String, Codable, Sendable {
    /// I scanned their invite and sent a request. Waiting for them to accept.
    case requested
    /// I accepted their request and shared my history. Waiting for their share to arrive.
    case awaitingTheirShare
    /// Both histories shared.
    case active
}

/// My private record of a friendship (lives in the Private zone; synced across my devices).
public struct FriendLink: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var userID: UserID?
    /// Cached identity for display before their shared zone arrives.
    public var person: PersonRef?
    public var status: FriendLinkStatus
    /// Token I listen on for pings from this friend.
    public var myInbox: InboxToken
    /// Token I address pings to.
    public var theirInbox: InboxToken?
    /// Base64url AES key for encrypted ping payloads in this friendship.
    public var pairKey: String
    public var notify: FriendNotifyLevel
    public var theirShareURL: String?
    /// For `.requested`: the invite token I answered.
    public var inviteToken: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), userID: UserID? = nil, person: PersonRef? = nil, status: FriendLinkStatus, myInbox: InboxToken, theirInbox: InboxToken? = nil, pairKey: String, notify: FriendNotifyLevel = .every, theirShareURL: String? = nil, inviteToken: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.userID = userID
        self.person = person
        self.status = status
        self.myInbox = myInbox
        self.theirInbox = theirInbox
        self.pairKey = pairKey
        self.notify = notify
        self.theirShareURL = theirShareURL
        self.inviteToken = inviteToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// An invite I created (QR / link). Anyone holding it can *request* friendship; I still confirm each request.
public struct OutgoingInvite: Codable, Hashable, Sendable, Identifiable {
    public var token: InboxToken
    public var secret: String
    public var createdAt: Date
    public var expiresAt: Date

    public var id: String { token }

    public init(token: InboxToken = TokenFactory.make(), secret: String = TokenFactory.makeKeyData().base64URLEncodedString(), createdAt: Date = Date(), lifetime: TimeInterval = 7 * 24 * 3600) {
        self.token = token
        self.secret = secret
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
    }

    public func isValid(now: Date) -> Bool { now < expiresAt }
}

/// A friend request somebody sent to one of my invites. Device-local until acted on.
public struct IncomingFriendRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var inviteToken: InboxToken
    public var person: PersonRef
    public var theirInbox: InboxToken
    public var pairKey: String
    public var receivedAt: Date

    public init(id: String, inviteToken: InboxToken, person: PersonRef, theirInbox: InboxToken, pairKey: String, receivedAt: Date) {
        self.id = id
        self.inviteToken = inviteToken
        self.person = person
        self.theirInbox = theirInbox
        self.pairKey = pairKey
        self.receivedAt = receivedAt
    }
}

/// Read-only copy of a friend's shared "Me" zone.
public struct FriendCache: Codable, Hashable, Sendable {
    public var userID: UserID
    public var zone: ZoneRef
    public var profile: UserProfile?
    public var events: [UUID: PoopEvent]
    public var achievements: [AchievementID: AchievementUnlock]
    public var cosmetics: [CosmeticID: CosmeticUnlock]
    public var lastFetchedAt: Date?

    public init(userID: UserID, zone: ZoneRef, profile: UserProfile? = nil, events: [UUID: PoopEvent] = [:], achievements: [AchievementID: AchievementUnlock] = [:], cosmetics: [CosmeticID: CosmeticUnlock] = [:], lastFetchedAt: Date? = nil) {
        self.userID = userID
        self.zone = zone
        self.profile = profile
        self.events = events
        self.achievements = achievements
        self.cosmetics = cosmetics
        self.lastFetchedAt = lastFetchedAt
    }

    public var liveEvent: PoopEvent? {
        events.values.filter { $0.isLive }.max(by: { $0.startedAt < $1.startedAt })
    }
}

// MARK: - Groups

public enum GroupObject: String, Codable, CaseIterable, Sendable {
    case toilet, roll, crown, plunger, rubberDuck, poop, rocket, pizza, skull, star

    public var emoji: String {
        switch self {
        case .toilet: return "🚽"
        case .roll: return "🧻"
        case .crown: return "👑"
        case .plunger: return "🪠"
        case .rubberDuck: return "🦆"
        case .poop: return "💩"
        case .rocket: return "🚀"
        case .pizza: return "🍕"
        case .skull: return "💀"
        case .star: return "⭐️"
        }
    }
}

/// My private record of a group membership (Private zone).
public struct GroupLink: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var zone: ZoneRef
    public var isOwner: Bool
    public var shareURL: String?
    /// Token I listen on for this group's pings.
    public var myInbox: InboxToken
    public var notify: GroupNotifyLevel
    public var shareEvents: Bool
    public var shareLocations: Bool
    public var nameCache: String
    public var joinedAt: Date
    public var updatedAt: Date

    public init(id: UUID, zone: ZoneRef, isOwner: Bool, shareURL: String? = nil, myInbox: InboxToken = TokenFactory.make(), notify: GroupNotifyLevel = .all, shareEvents: Bool = true, shareLocations: Bool = false, nameCache: String, joinedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.zone = zone
        self.isOwner = isOwner
        self.shareURL = shareURL
        self.myInbox = myInbox
        self.notify = notify
        self.shareEvents = shareEvents
        self.shareLocations = shareLocations
        self.nameCache = nameCache
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }
}

public struct GroupInfo: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var object: GroupObject
    public var color: IdentityColor
    public var createdBy: UserID
    /// Base64url AES key for group ping payloads. Only members can read it.
    public var key: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, object: GroupObject, color: IdentityColor, createdBy: UserID, key: String = TokenFactory.makeKeyData().base64URLEncodedString(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.object = object
        self.color = color
        self.createdBy = createdBy
        self.key = key
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum GroupRole: String, Codable, Sendable { case owner, member }

/// Each member writes (and owns) their own member record in the group zone.
public struct GroupMember: Codable, Hashable, Sendable, Identifiable {
    public var person: PersonRef
    public var inbox: InboxToken
    public var role: GroupRole
    public var joinedAt: Date
    public var updatedAt: Date

    public var id: UserID { person.id }

    public init(person: PersonRef, inbox: InboxToken, role: GroupRole, joinedAt: Date = Date(), updatedAt: Date = Date()) {
        self.person = person
        self.inbox = inbox
        self.role = role
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }
}

/// A poop mirrored into a group zone. Group members see these, never the full personal history.
public struct GroupEvent: Codable, Hashable, Sendable, Identifiable, PoopLike {
    public var id: UUID
    public var ownerID: UserID
    public var source: PoopSource
    public var startedAt: Date
    public var endedAt: Date?
    public var location: PoopLocation?
    public var pwmSessionID: UUID?
    public var partyID: UUID?
    public var updatedAt: Date

    public init(id: UUID, ownerID: UserID, source: PoopSource, startedAt: Date, endedAt: Date?, location: PoopLocation?, pwmSessionID: UUID?, partyID: UUID?, updatedAt: Date = Date()) {
        self.id = id
        self.ownerID = ownerID
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.location = location
        self.pwmSessionID = pwmSessionID
        self.partyID = partyID
        self.updatedAt = updatedAt
    }

    public init(event: PoopEvent, ownerID: UserID, includeLocation: Bool) {
        self.init(id: event.id, ownerID: ownerID, source: event.source, startedAt: event.startedAt, endedAt: event.endedAt, location: includeLocation ? event.location : nil, pwmSessionID: event.pwmSessionID, partyID: event.partyID, updatedAt: event.updatedAt)
    }

    public var isLive: Bool { source == .timed && endedAt == nil }
}
