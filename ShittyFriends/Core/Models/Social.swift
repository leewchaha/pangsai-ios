import Foundation

/// Identifies a sync "zone" independently of the backend. A zone is one person's history
/// (`Me`, owner = that person), my private settings/links (`Private`), a group (`G-<id>`) or an
/// ad-hoc Poop With Me / party space between friends (`S-<id>`).
/// `ownerName == ZoneRef.currentUser` means I own it.
public struct ZoneRef: Codable, Hashable, Sendable, CustomStringConvertible {
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

    public static func group(_ id: UUID, ownerID: UserID?, me: UserID?) -> ZoneRef {
        ZoneRef(ownerName: (ownerID == nil || ownerID == me) ? currentUser : ownerID!, zoneName: ZoneNames.group(id))
    }

    public static func space(_ id: UUID, ownerID: UserID?, me: UserID?) -> ZoneRef {
        ZoneRef(ownerName: (ownerID == nil || ownerID == me) ? currentUser : ownerID!, zoneName: ZoneNames.session(id))
    }

    public var isGroup: Bool { zoneName.hasPrefix(ZoneNames.groupPrefix) }
    public var isSpace: Bool { zoneName.hasPrefix(ZoneNames.sessionPrefix) }
    public var groupID: UUID? { ZoneNames.groupID(fromZoneName: zoneName) }
    public var spaceID: UUID? { ZoneNames.spaceID(fromZoneName: zoneName) }
}

public enum ZoneNames {
    /// Readable by full friends: profile, entire poop history, achievements, cosmetics.
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

    public static func spaceID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(sessionPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(sessionPrefix.count)))
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
    /// I answered their invite and sent a request. Waiting for them to accept.
    case requested
    /// I accepted their request; waiting for the friendship record to come back from the server.
    case awaitingTheirShare
    /// Friends: both histories are visible.
    case active
}

/// My private record of a friendship (Private zone; synced across my devices).
public struct FriendLink: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var userID: UserID?
    /// Cached identity for display before their profile arrives.
    public var person: PersonRef?
    public var status: FriendLinkStatus
    public var notify: FriendNotifyLevel
    /// For `.requested`: the invite token I answered, and the request record I created.
    public var inviteToken: String?
    public var requestID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), userID: UserID? = nil, person: PersonRef? = nil, status: FriendLinkStatus, notify: FriendNotifyLevel = .every, inviteToken: String? = nil, requestID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.userID = userID
        self.person = person
        self.status = status
        self.notify = notify
        self.inviteToken = inviteToken
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, userID, person, status, notify, inviteToken, requestID, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userID = try c.decodeIfPresent(UserID.self, forKey: .userID)
        person = try? c.decodeIfPresent(PersonRef.self, forKey: .person)
        status = (try? c.decode(FriendLinkStatus.self, forKey: .status)) ?? .active
        notify = (try? c.decode(FriendNotifyLevel.self, forKey: .notify)) ?? .every
        inviteToken = try? c.decodeIfPresent(String.self, forKey: .inviteToken)
        requestID = try? c.decodeIfPresent(String.self, forKey: .requestID)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

/// An invite I created (QR / link). Anyone holding it can *request* friendship; I still confirm each request.
public struct OutgoingInvite: Codable, Hashable, Sendable, Identifiable {
    public var token: String
    public var createdAt: Date
    public var expiresAt: Date

    public var id: String { token }

    public init(token: String = TokenFactory.make(), createdAt: Date = Date(), lifetime: TimeInterval = 7 * 24 * 3600) {
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
    }

    private enum CodingKeys: String, CodingKey { case token, createdAt, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        expiresAt = (try? c.decode(Date.self, forKey: .expiresAt)) ?? createdAt.addingTimeInterval(7 * 24 * 3600)
    }

    public func isValid(now: Date) -> Bool { now < expiresAt }
}

/// A friend request somebody sent to one of my invites (a `friendRequests` record addressed to me).
public struct IncomingFriendRequest: Codable, Hashable, Sendable, Identifiable {
    /// The request record's id.
    public var id: String
    public var inviteToken: String
    public var person: PersonRef
    public var receivedAt: Date

    public init(id: String, inviteToken: String, person: PersonRef, receivedAt: Date) {
        self.id = id
        self.inviteToken = inviteToken
        self.person = person
        self.receivedAt = receivedAt
    }
}

/// Read-only copy of a friend's history.
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

public enum GroupLinkStatus: String, Codable, Sendable {
    /// I asked to join; the owner hasn't decided yet.
    case requested
    /// Member (or owner).
    case active
}

/// My private record of a group membership (Private zone).
public struct GroupLink: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var zone: ZoneRef
    public var isOwner: Bool
    public var status: GroupLinkStatus
    public var notify: GroupNotifyLevel
    public var shareEvents: Bool
    public var shareLocations: Bool
    public var nameCache: String
    public var joinedAt: Date
    public var updatedAt: Date

    public init(id: UUID, zone: ZoneRef, isOwner: Bool, status: GroupLinkStatus = .active, notify: GroupNotifyLevel = .all, shareEvents: Bool = true, shareLocations: Bool = false, nameCache: String, joinedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.zone = zone
        self.isOwner = isOwner
        self.status = status
        self.notify = notify
        self.shareEvents = shareEvents
        self.shareLocations = shareLocations
        self.nameCache = nameCache
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, zone, isOwner, status, notify, shareEvents, shareLocations, nameCache, joinedAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        zone = try c.decode(ZoneRef.self, forKey: .zone)
        isOwner = (try? c.decode(Bool.self, forKey: .isOwner)) ?? false
        status = (try? c.decode(GroupLinkStatus.self, forKey: .status)) ?? .active
        notify = (try? c.decode(GroupNotifyLevel.self, forKey: .notify)) ?? .all
        shareEvents = (try? c.decode(Bool.self, forKey: .shareEvents)) ?? true
        shareLocations = (try? c.decode(Bool.self, forKey: .shareLocations)) ?? false
        nameCache = (try? c.decode(String.self, forKey: .nameCache)) ?? ""
        joinedAt = (try? c.decode(Date.self, forKey: .joinedAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? joinedAt
    }
}

public struct GroupInfo: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var object: GroupObject
    public var color: IdentityColor
    public var createdBy: UserID
    /// Share this code (QR / link) to let people *ask* to join; the owner approves each one.
    public var inviteCode: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, object: GroupObject, color: IdentityColor, createdBy: UserID, inviteCode: String = TokenFactory.make(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.object = object
        self.color = color
        self.createdBy = createdBy
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, object, color, createdBy, inviteCode, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        object = (try? c.decode(GroupObject.self, forKey: .object)) ?? .toilet
        color = (try? c.decode(IdentityColor.self, forKey: .color)) ?? .violet
        createdBy = (try? c.decode(UserID.self, forKey: .createdBy)) ?? ""
        inviteCode = (try? c.decode(String.self, forKey: .inviteCode)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

public enum GroupRole: String, Codable, Sendable { case owner, member }

/// One row per member in the group space. The owner (through the server) creates it; the member keeps
/// their own identity fresh in it.
public struct GroupMember: Codable, Hashable, Sendable, Identifiable {
    public var person: PersonRef
    public var role: GroupRole
    public var joinedAt: Date
    public var updatedAt: Date

    public var id: UserID { person.id }

    public init(person: PersonRef, role: GroupRole, joinedAt: Date = Date(), updatedAt: Date = Date()) {
        self.person = person
        self.role = role
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case person, role, joinedAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = try c.decode(PersonRef.self, forKey: .person)
        role = (try? c.decode(GroupRole.self, forKey: .role)) ?? .member
        joinedAt = (try? c.decode(Date.self, forKey: .joinedAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? joinedAt
    }
}

/// Someone asked to join a group I own (server-created when they open the link).
public struct GroupJoinRequest: Codable, Hashable, Sendable, Identifiable {
    public var person: PersonRef
    public var createdAt: Date

    public var id: UserID { person.id }

    public init(person: PersonRef, createdAt: Date = Date()) {
        self.person = person
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case person, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = try c.decode(PersonRef.self, forKey: .person)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
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
    /// Mirrors of the owner's flags, so the group can apply the same counting rule
    /// (`countsForRanking`) to its leaderboard, trophies and highlights.
    public var manuallyAdjusted: Bool
    public var imported: Bool
    public var updatedAt: Date

    public init(id: UUID, ownerID: UserID, source: PoopSource, startedAt: Date, endedAt: Date?, location: PoopLocation?, pwmSessionID: UUID?, partyID: UUID?, manuallyAdjusted: Bool = false, imported: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.ownerID = ownerID
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.location = location
        self.pwmSessionID = pwmSessionID
        self.partyID = partyID
        self.manuallyAdjusted = manuallyAdjusted
        self.imported = imported
        self.updatedAt = updatedAt
    }

    public init(event: PoopEvent, ownerID: UserID, includeLocation: Bool) {
        self.init(id: event.id, ownerID: ownerID, source: event.source, startedAt: event.startedAt, endedAt: event.endedAt, location: includeLocation ? event.location : nil, pwmSessionID: event.pwmSessionID, partyID: event.partyID, manuallyAdjusted: event.manuallyAdjusted, imported: event.imported, updatedAt: event.updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerID, source, startedAt, endedAt, location, pwmSessionID, partyID, manuallyAdjusted, imported, updatedAt
    }

    /// Group copies written by older app versions carry no flags.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ownerID = try c.decode(UserID.self, forKey: .ownerID)
        source = try c.decode(PoopSource.self, forKey: .source)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        location = try c.decodeIfPresent(PoopLocation.self, forKey: .location)
        pwmSessionID = try c.decodeIfPresent(UUID.self, forKey: .pwmSessionID)
        partyID = try c.decodeIfPresent(UUID.self, forKey: .partyID)
        manuallyAdjusted = (try? c.decodeIfPresent(Bool.self, forKey: .manuallyAdjusted)) ?? false
        imported = (try? c.decodeIfPresent(Bool.self, forKey: .imported)) ?? false
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? startedAt
    }

    public var isLive: Bool { source == .timed && endedAt == nil }
}
