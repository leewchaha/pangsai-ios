import Foundation

// MARK: - Poop With Me

public enum PWMState: String, Codable, Sendable { case open, ended }

public struct PWMSession: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var creatorID: UserID
    public var groupID: UUID?
    public var state: PWMState
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), creatorID: UserID, groupID: UUID? = nil, state: PWMState = .open, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.creatorID = creatorID
        self.groupID = groupID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ParticipantStatus: String, Codable, Sendable {
    case invited, joined, done, declined
}

public struct PWMParticipant: Codable, Hashable, Sendable, Identifiable {
    public var sessionID: UUID
    public var person: PersonRef
    public var status: ParticipantStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var eventID: UUID?
    public var updatedAt: Date

    public var id: UserID { person.id }

    public init(sessionID: UUID, person: PersonRef, status: ParticipantStatus, startedAt: Date? = nil, endedAt: Date? = nil, eventID: UUID? = nil, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.person = person
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.eventID = eventID
        self.updatedAt = updatedAt
    }
}

public struct Reaction: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var senderID: UserID
    public var kind: ReactionKind
    public var cosmetic: CosmeticID?
    public var at: Date

    public init(id: UUID = UUID(), sessionID: UUID, senderID: UserID, kind: ReactionKind, cosmetic: CosmeticID? = nil, at: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.senderID = senderID
        self.kind = kind
        self.cosmetic = cosmetic
        self.at = at
    }
}

// MARK: - Poop Parties

public enum PartyStatus: String, Codable, Sendable { case scheduled, cancelled }

public struct Party: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var creatorID: UserID
    public var groupID: UUID?
    public var title: String
    public var scheduledAt: Date
    public var status: PartyStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), creatorID: UserID, groupID: UUID?, title: String, scheduledAt: Date, status: PartyStatus = .scheduled, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.creatorID = creatorID
        self.groupID = groupID
        self.title = title
        self.scheduledAt = scheduledAt
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Joinable from 10 minutes before until 60 minutes after the scheduled time.
    public func isJoinable(now: Date) -> Bool {
        status == .scheduled && now >= scheduledAt.addingTimeInterval(-10 * 60) && now <= scheduledAt.addingTimeInterval(60 * 60)
    }

    public func isOver(now: Date) -> Bool { now > scheduledAt.addingTimeInterval(60 * 60) || status == .cancelled }
}

public enum RSVPResponse: String, Codable, CaseIterable, Sendable {
    case yes, maybe, no

    public var symbol: String {
        switch self { case .yes: return "✓"; case .maybe: return "?"; case .no: return "✕" }
    }
}

public struct PartyRSVP: Codable, Hashable, Sendable, Identifiable {
    public var partyID: UUID
    public var person: PersonRef
    public var response: RSVPResponse
    public var joinedAt: Date?
    public var eventID: UUID?
    public var updatedAt: Date

    public var id: UserID { person.id }

    public init(partyID: UUID, person: PersonRef, response: RSVPResponse, joinedAt: Date? = nil, eventID: UUID? = nil, updatedAt: Date = Date()) {
        self.partyID = partyID
        self.person = person
        self.response = response
        self.joinedAt = joinedAt
        self.eventID = eventID
        self.updatedAt = updatedAt
    }
}

// MARK: - Session spaces

public enum SpaceKind: String, Codable, Sendable { case pwm, party }

/// An ad-hoc space used for a Poop With Me session or a Party between friends who don't share a
/// group. Owned by the creator; its members are the friends they invited.
public struct SpaceLink: Codable, Hashable, Sendable, Identifiable {
    public var zone: ZoneRef
    public var kind: SpaceKind
    public var isOwner: Bool
    public var title: String
    public var participantIDs: [UserID]
    public var createdAt: Date
    public var expiresAt: Date

    public var id: ZoneRef { zone }

    public init(zone: ZoneRef, kind: SpaceKind, isOwner: Bool, title: String = "", participantIDs: [UserID] = [], createdAt: Date = Date(), expiresAt: Date) {
        self.zone = zone
        self.kind = kind
        self.isOwner = isOwner
        self.title = title
        self.participantIDs = participantIDs
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case zone, kind, isOwner, title, participantIDs, createdAt, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decode(ZoneRef.self, forKey: .zone)
        kind = (try? c.decode(SpaceKind.self, forKey: .kind)) ?? .pwm
        isOwner = (try? c.decode(Bool.self, forKey: .isOwner)) ?? false
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        participantIDs = (try? c.decode([UserID].self, forKey: .participantIDs)) ?? []
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        expiresAt = (try? c.decode(Date.self, forKey: .expiresAt)) ?? createdAt.addingTimeInterval(6 * 3600)
    }
}

/// Local copy of any group space or ad-hoc session space.
public struct ZoneCache: Codable, Hashable, Sendable {
    public var zone: ZoneRef
    public var group: GroupInfo?
    public var members: [UserID: GroupMember]
    /// Owner only: people waiting for approval.
    public var requests: [UserID: GroupJoinRequest]
    public var events: [UUID: GroupEvent]
    public var sessions: [UUID: PWMSession]
    /// Keyed by session id, then user id.
    public var participants: [UUID: [UserID: PWMParticipant]]
    public var reactions: [UUID: Reaction]
    public var parties: [UUID: Party]
    /// Keyed by party id, then user id.
    public var rsvps: [UUID: [UserID: PartyRSVP]]

    public init(zone: ZoneRef) {
        self.zone = zone
        self.group = nil
        self.members = [:]
        self.requests = [:]
        self.events = [:]
        self.sessions = [:]
        self.participants = [:]
        self.reactions = [:]
        self.parties = [:]
        self.rsvps = [:]
    }

    private enum CodingKeys: String, CodingKey { case zone, group, members, requests, events, sessions, participants, reactions, parties, rsvps }

    /// The cache is disposable (it re-syncs), but a missing field must not throw the whole file away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decode(ZoneRef.self, forKey: .zone)
        group = try? c.decodeIfPresent(GroupInfo.self, forKey: .group)
        members = (try? c.decode([UserID: GroupMember].self, forKey: .members)) ?? [:]
        requests = (try? c.decode([UserID: GroupJoinRequest].self, forKey: .requests)) ?? [:]
        events = (try? c.decode([UUID: GroupEvent].self, forKey: .events)) ?? [:]
        sessions = (try? c.decode([UUID: PWMSession].self, forKey: .sessions)) ?? [:]
        participants = (try? c.decode([UUID: [UserID: PWMParticipant]].self, forKey: .participants)) ?? [:]
        reactions = (try? c.decode([UUID: Reaction].self, forKey: .reactions)) ?? [:]
        parties = (try? c.decode([UUID: Party].self, forKey: .parties)) ?? [:]
        rsvps = (try? c.decode([UUID: [UserID: PartyRSVP]].self, forKey: .rsvps)) ?? [:]
    }
}
