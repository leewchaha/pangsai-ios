import Foundation

/// Identifies one syncable record independently of the backend.
public enum RecordRef: Hashable, Sendable {
    // My "Me" zone (shared with friends)
    case profile
    case event(UUID)
    case achievement(AchievementID)
    case cosmetic(CosmeticID)
    // My "Private" zone
    case settings
    case friendLink(UUID)
    case groupLink(UUID)
    case invite(String)
    case spaceLink(ZoneRef)
    // Group zones / session zones
    case groupInfo(ZoneRef)
    case member(ZoneRef, UserID)
    case joinRequest(ZoneRef, UserID)
    case groupEvent(ZoneRef, UUID)
    case pwmSession(ZoneRef, UUID)
    case participant(ZoneRef, UUID, UserID)
    case reaction(ZoneRef, UUID)
    case party(ZoneRef, UUID)
    case rsvp(ZoneRef, UUID, UserID)

    public var zone: ZoneRef {
        switch self {
        case .profile, .event, .achievement, .cosmetic: return .me
        case .settings, .friendLink, .groupLink, .invite, .spaceLink: return .privateZone
        case .groupInfo(let z), .member(let z, _), .joinRequest(let z, _), .groupEvent(let z, _), .pwmSession(let z, _),
             .participant(let z, _, _), .reaction(let z, _), .party(let z, _), .rsvp(let z, _, _):
            return z
        }
    }

    public var recordType: String {
        switch self {
        case .profile: return RecordTypes.profile
        case .event: return RecordTypes.event
        case .achievement: return RecordTypes.achievement
        case .cosmetic: return RecordTypes.cosmetic
        case .settings: return RecordTypes.settings
        case .friendLink: return RecordTypes.friendLink
        case .groupLink: return RecordTypes.groupLink
        case .invite: return RecordTypes.invite
        case .spaceLink: return RecordTypes.spaceLink
        case .groupInfo: return RecordTypes.groupInfo
        case .member: return RecordTypes.member
        case .joinRequest: return RecordTypes.joinRequest
        case .groupEvent: return RecordTypes.groupEvent
        case .pwmSession: return RecordTypes.pwmSession
        case .participant: return RecordTypes.participant
        case .reaction: return RecordTypes.reaction
        case .party: return RecordTypes.party
        case .rsvp: return RecordTypes.rsvp
        }
    }

    /// Stable, parseable record name (see `RecordRef.parse`). Also the local persistence key.
    public var recordName: String {
        switch self {
        case .profile: return "profile"
        case .event(let id): return "E-" + id.uuidString
        case .achievement(let id): return "A-" + id.rawValue
        case .cosmetic(let id): return "C-" + id.rawValue
        case .settings: return "settings"
        case .friendLink(let id): return "FL-" + id.uuidString
        case .groupLink(let id): return "GL-" + id.uuidString
        case .invite(let token): return "I-" + token
        case .spaceLink(let z): return "SL-" + Data("\(z.ownerName)/\(z.zoneName)".utf8).base64URLEncodedString()
        case .groupInfo: return "info"
        case .member(_, let uid): return "M-" + uid
        case .joinRequest(_, let uid): return "JR-" + uid
        case .groupEvent(_, let id): return "GE-" + id.uuidString
        case .pwmSession(_, let id): return "PS-" + id.uuidString
        case .participant(_, let sid, let uid): return "PP-" + sid.uuidString + "-" + uid
        case .reaction(_, let id): return "R-" + id.uuidString
        case .party(_, let id): return "PT-" + id.uuidString
        case .rsvp(_, let pid, let uid): return "RV-" + pid.uuidString + "-" + uid
        }
    }

    /// Inverse of `recordName` for a record found in `zone`.
    public static func parse(recordName name: String, zone: ZoneRef) -> RecordRef? {
        func uuid(after prefix: String) -> UUID? {
            guard name.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(prefix.count).prefix(36)))
        }
        func tail(after prefix: String) -> String? {
            guard name.hasPrefix(prefix) else { return nil }
            let rest = name.dropFirst(prefix.count)
            guard rest.count > 37 else { return nil }
            return String(rest.dropFirst(37))
        }

        if zone.zoneName == ZoneNames.me {
            if name == "profile" { return .profile }
            if let id = uuid(after: "E-") { return .event(id) }
            if name.hasPrefix("A-"), let id = AchievementID(rawValue: String(name.dropFirst(2))) { return .achievement(id) }
            if name.hasPrefix("C-"), let id = CosmeticID(rawValue: String(name.dropFirst(2))) { return .cosmetic(id) }
            return nil
        }
        if zone.zoneName == ZoneNames.private {
            if name == "settings" { return .settings }
            if let id = uuid(after: "FL-") { return .friendLink(id) }
            if let id = uuid(after: "GL-") { return .groupLink(id) }
            if name.hasPrefix("I-") { return .invite(String(name.dropFirst(2))) }
            if name.hasPrefix("SL-"),
               let data = Data(base64URLEncoded: String(name.dropFirst(3))),
               let s = String(data: data, encoding: .utf8),
               let slash = s.firstIndex(of: "/") {
                return .spaceLink(ZoneRef(ownerName: String(s[..<slash]), zoneName: String(s[s.index(after: slash)...])))
            }
            return nil
        }
        if name == "info" { return .groupInfo(zone) }
        if name.hasPrefix("M-") { return .member(zone, String(name.dropFirst(2))) }
        if name.hasPrefix("JR-") { return .joinRequest(zone, String(name.dropFirst(3))) }
        if let id = uuid(after: "GE-") { return .groupEvent(zone, id) }
        if let id = uuid(after: "PS-") { return .pwmSession(zone, id) }
        if let sid = uuid(after: "PP-"), let uid = tail(after: "PP-") { return .participant(zone, sid, uid) }
        if let id = uuid(after: "R-") { return .reaction(zone, id) }
        if let id = uuid(after: "PT-") { return .party(zone, id) }
        if let pid = uuid(after: "RV-"), let uid = tail(after: "RV-") { return .rsvp(zone, pid, uid) }
        return nil
    }
}

public enum RecordTypes {
    public static let profile = "Profile"
    public static let event = "PoopEvent"
    public static let achievement = "Achievement"
    public static let cosmetic = "Cosmetic"
    public static let settings = "Settings"
    public static let friendLink = "FriendLink"
    public static let groupLink = "GroupLink"
    public static let invite = "Invite"
    public static let spaceLink = "SpaceLink"
    public static let groupInfo = "GroupInfo"
    public static let member = "Member"
    public static let joinRequest = "JoinRequest"
    public static let groupEvent = "GroupEvent"
    public static let pwmSession = "PWMSession"
    public static let participant = "PWMParticipant"
    public static let reaction = "Reaction"
    public static let party = "Party"
    public static let rsvp = "RSVP"
}

/// A decoded record coming from the backend.
public enum RemoteRecord: Hashable, Sendable {
    case profile(UserProfile)
    case event(PoopEvent)
    case achievement(AchievementUnlock)
    case cosmetic(CosmeticUnlock)
    case settings(AppSettings)
    case friendLink(FriendLink)
    case groupLink(GroupLink)
    case invite(OutgoingInvite)
    case spaceLink(SpaceLink)
    case groupInfo(GroupInfo)
    case member(GroupMember)
    case joinRequest(GroupJoinRequest)
    case groupEvent(GroupEvent)
    case pwmSession(PWMSession)
    case participant(PWMParticipant)
    case reaction(Reaction)
    case party(Party)
    case rsvp(PartyRSVP)
}

public enum RemoteChange: Hashable, Sendable {
    case upsert(RemoteRecord, zone: ZoneRef)
    /// Same as `upsert`, with the user who wrote the record. Group/session records are checked against
    /// who is allowed to write them (belt and braces: the server rules enforce the same authorship).
    case upsertFrom(RemoteRecord, zone: ZoneRef, writer: UserID)
    /// `ref` was parsed in `zone` (needed because "Me" refs don't encode the owner).
    case delete(RecordRef, zone: ZoneRef)
    /// The whole zone is gone for me: a friend unfriended me, a group was deleted or I was removed,
    /// a space expired.
    case zoneDeleted(ZoneRef)
}

// MARK: - Effects

public enum HapticKind: Sendable, Hashable { case logHeavy, tapLight, tapCritical, success, warning, reaction }

/// Alerts the store wants other people to get. With the Firebase backend, Poop With Me and party
/// invites/joins are pushed by the server when their records land, so only `.poop` needs the app
/// to do anything (announce the event after the Undo window).
public enum PingIntent: Hashable, Sendable {
    /// Notify friends + groups that I started / logged a poop.
    case poop(eventID: UUID, kind: PingKind)
    case pwmInvite(zone: ZoneRef, sessionID: UUID, invitees: [UserID])
    case pwmJoin(zone: ZoneRef, sessionID: UUID)
    case partyInvite(zone: ZoneRef, partyID: UUID, invitees: [UserID])
}

/// Side effects the platform layer executes on behalf of the store.
public enum Effect: Hashable, Sendable {
    case save(RecordRef)
    case delete(RecordRef)
    case ping(PingIntent)
    /// Withdraw anything still pending about an event (an unsent "is pooping" announcement).
    case cancelPings(eventID: UUID)
    case scheduleLongSessionReminder(eventID: UUID, at: Date)
    case cancelLongSessionReminder(eventID: UUID)
    case scheduleParty(zone: ZoneRef, partyID: UUID)
    case cancelParty(partyID: UUID)
    case requestLocation(eventID: UUID)
    /// Friend / group / invite set changed: the platform re-attaches its listeners.
    case refreshSubscriptions
    /// Settings that the Notification Service Extension reads changed (private lock screen, quiet hours).
    case refreshDirectory
    case rescheduleSummaries
    case achievementsUnlocked([AchievementID])
    case cosmeticUnlocked(CosmeticID)
    /// A friendship ended on my side (unfriend / block): tell the server.
    case friendZoneGone(UserID)
    /// A group/session space I own must exist on the server before records are saved into it.
    case ensureZone(ZoneRef)
    case haptic(HapticKind)
}
