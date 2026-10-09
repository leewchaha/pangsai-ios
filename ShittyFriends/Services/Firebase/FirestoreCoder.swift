import FirebaseFirestore
import Foundation

/// Maps store entities <-> Firestore documents. Every model is written with its real fields (the
/// security rules look at `ownerID`, `creatorID`, `person.id`, `status`, ...), dates as Timestamps.
enum FirestoreCoder {
    static let encoder: Firestore.Encoder = {
        let e = Firestore.Encoder()
        e.dateEncodingStrategy = .timestamp
        return e
    }()

    static let decoder: Firestore.Decoder = {
        let d = Firestore.Decoder()
        d.dateDecodingStrategy = .timestamp
        return d
    }()

    // MARK: - Encode

    /// Builds the document for `ref` from current store state. Returns nil if the entity no longer exists.
    @MainActor
    static func fields(for ref: RecordRef, store: Store) -> [String: Any]? {
        let my = store.my
        let cache = store.cache
        func enc<T: Encodable>(_ v: T?) -> [String: Any]? {
            guard let v, let dict = try? encoder.encode(v) else { return nil }
            return dict
        }
        switch ref {
        case .profile: return enc(my.profile)
        case .event(let id): return enc(my.events[id])
        case .achievement(let id): return enc(my.achievements[id])
        case .cosmetic(let id): return enc(my.cosmetics[id])
        case .settings: return enc(my.settings)
        case .friendLink(let id): return enc(my.friendLinks[id])
        case .groupLink(let id): return enc(my.groupLinks[id])
        case .invite(let token): return enc(my.invites[token])
        case .spaceLink(let zone): return enc(my.spaceLinks[zone])
        case .groupInfo(let zone): return enc(cache.zones[zone]?.group)
        case .member(let zone, let uid): return enc(cache.zones[zone]?.members[uid])
        case .joinRequest(let zone, let uid): return enc(cache.zones[zone]?.requests[uid])
        case .groupEvent(let zone, let id): return enc(cache.zones[zone]?.events[id])
        case .pwmSession(let zone, let id): return enc(cache.zones[zone]?.sessions[id])
        case .participant(let zone, let sid, let uid): return enc(cache.zones[zone]?.participants[sid]?[uid])
        case .reaction(let zone, let id): return enc(cache.zones[zone]?.reactions[id])
        case .party(let zone, let id): return enc(cache.zones[zone]?.parties[id])
        case .rsvp(let zone, let pid, let uid): return enc(cache.zones[zone]?.rsvps[pid]?[uid])
        }
    }

    /// Group / member / invite documents carry fields the client's models don't (structural lists the
    /// server owns), so those are merged, never replaced.
    static func mergesFields(_ ref: RecordRef) -> Bool {
        switch ref {
        case .groupInfo, .member: return true
        default: return false
        }
    }

    // MARK: - Decode

    /// Which collection (last path component of the parent) a document lives in.
    enum Kind: String {
        case events, achievements, cosmetics, friendLinks, groupLinks, spaceLinks, invites
        case members, requests, sessions, participants, reactions, parties, rsvps
        case users, groups, spaces
        case `private`
    }

    static func decode(kind: Kind, documentID: String, data: [String: Any], inZone zone: ZoneRef) -> RemoteRecord? {
        func dec<T: Decodable>(_ type: T.Type) -> T? { try? decoder.decode(type, from: data) }
        let personal = zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private
        switch kind {
        case .users: return dec(UserProfile.self).map { .profile($0) }
        case .groups: return dec(GroupInfo.self).map { .groupInfo($0) }
        case .spaces: return nil
        case .events:
            return personal ? dec(PoopEvent.self).map { .event($0) } : dec(GroupEvent.self).map { .groupEvent($0) }
        case .achievements: return dec(AchievementUnlock.self).map { .achievement($0) }
        case .cosmetics: return dec(CosmeticUnlock.self).map { .cosmetic($0) }
        case .private: return documentID == "settings" ? dec(AppSettings.self).map { .settings($0) } : nil
        case .friendLinks: return dec(FriendLink.self).map { .friendLink($0) }
        case .groupLinks: return dec(GroupLink.self).map { .groupLink($0) }
        case .spaceLinks: return dec(SpaceLink.self).map { .spaceLink($0) }
        case .invites: return dec(OutgoingInvite.self).map { .invite($0) }
        case .members: return dec(GroupMember.self).map { .member($0) }
        case .requests: return dec(GroupJoinRequest.self).map { .joinRequest($0) }
        case .sessions: return dec(PWMSession.self).map { .pwmSession($0) }
        case .participants: return dec(PWMParticipant.self).map { .participant($0) }
        case .reactions: return dec(Reaction.self).map { .reaction($0) }
        case .parties: return dec(Party.self).map { .party($0) }
        case .rsvps: return dec(PartyRSVP.self).map { .rsvp($0) }
        }
    }

    /// The record reference a deleted document stood for (for `RemoteChange.delete`).
    static func ref(kind: Kind, documentID: String, inZone zone: ZoneRef) -> RecordRef? {
        func uuid() -> UUID? { UUID(uuidString: documentID) }
        func split() -> (UUID, UserID)? {
            guard documentID.count > 37, let id = UUID(uuidString: String(documentID.prefix(36))) else { return nil }
            return (id, String(documentID.dropFirst(37)))
        }
        let personal = zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private
        switch kind {
        case .events: return uuid().map { personal ? .event($0) : .groupEvent(zone, $0) }
        case .achievements: return AchievementID(rawValue: documentID).map { .achievement($0) }
        case .cosmetics: return CosmeticID(rawValue: documentID).map { .cosmetic($0) }
        case .friendLinks: return uuid().map { .friendLink($0) }
        case .groupLinks: return uuid().map { .groupLink($0) }
        case .spaceLinks: return uuid().map { .spaceLink(ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session($0))) }
        case .invites: return .invite(documentID)
        case .members: return .member(zone, documentID)
        case .requests: return .joinRequest(zone, documentID)
        case .sessions: return uuid().map { .pwmSession(zone, $0) }
        case .participants: return split().map { .participant(zone, $0.0, $0.1) }
        case .reactions: return uuid().map { .reaction(zone, $0) }
        case .parties: return uuid().map { .party(zone, $0) }
        case .rsvps: return split().map { .rsvp(zone, $0.0, $0.1) }
        case .users, .groups, .spaces, .private: return nil
        }
    }

    static func person(_ data: [String: Any]?) -> PersonRef? {
        guard let data else { return nil }
        return try? decoder.decode(PersonRef.self, from: data)
    }
}
