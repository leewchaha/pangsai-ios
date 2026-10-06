import Foundation

/// A ping ready to be sealed and written to the public database.
public struct OutgoingPing: Hashable, Sendable {
    /// Recipient inbox token.
    public var to: InboxToken
    public var kind: PingKind
    /// Group pings only: my inbox token in that group (lets the recipient show "@lee").
    public var from: InboxToken?
    public var payload: PingPayload
    /// Base64url key used to seal `payload` (pair key, group key or invite secret).
    public var key: String
    /// Set for poop pings so they can be withdrawn on DONE / delete.
    public var eventID: UUID?
    public var expiresAt: Date

    public init(to: InboxToken, kind: PingKind, from: InboxToken?, payload: PingPayload, key: String, eventID: UUID?, expiresAt: Date) {
        self.to = to
        self.kind = kind
        self.from = from
        self.payload = payload
        self.key = key
        self.eventID = eventID
        self.expiresAt = expiresAt
    }
}

/// A ping read back from the public database.
public struct IncomingPing: Hashable, Sendable {
    public var recordName: String
    public var to: InboxToken
    public var kind: PingKind
    public var from: InboxToken?
    public var ref: String?
    public var expiresAt: Date
    public var createdAt: Date?

    public init(recordName: String, to: InboxToken, kind: PingKind, from: InboxToken?, ref: String?, expiresAt: Date, createdAt: Date?) {
        self.recordName = recordName
        self.to = to
        self.kind = kind
        self.from = from
        self.ref = ref
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// One CloudKit query subscription on the public `Ping` type: `to IN tokens AND kind IN kinds`.
public struct SubscriptionSpec: Hashable, Sendable {
    public static let idPrefix = "ping."

    public var id: String
    public var tokens: [InboxToken]
    public var kinds: [PingKind]

    public init(id: String, tokens: [InboxToken], kinds: [PingKind]) {
        self.id = id
        self.tokens = tokens
        self.kinds = kinds
    }
}

/// What the app should do about an incoming ping.
public enum PingAction: Hashable, Sendable {
    /// Someone answered one of my invites (A side).
    case friendRequest(IncomingFriendRequest)
    /// The person whose invite I answered accepted me and shared their history (B side).
    case friendAccepted(linkID: UUID, person: PersonRef, theirInbox: InboxToken, shareURL: String)
    /// The person I accepted shared their history back (A side).
    case friendCompleted(linkID: UUID, shareURL: String)
    case pwmInvite(sessionID: UUID, groupID: UUID?, shareURL: String?)
    case partyInvite(partyID: UUID, groupID: UUID?, shareURL: String?)
    /// Something happened in a friend's zone or a group: fetch.
    case refreshShared
    case ignore(String)
}

/// Pure planning for the anonymous ping channel. Everything here runs (and is tested) on Linux.
public enum PingPlanner {
    /// Max tokens per subscription predicate. Keeps predicates small; more tokens -> more subscriptions.
    public static let tokensPerSubscription = 30

    // MARK: - Identity

    static func identity(_ store: Store) -> PingPayload {
        let p = store.profile
        return PingPayload(uid: store.userID, handle: p.handle, color: p.color.rawValue, avatar: p.avatar.compact, cosmetic: p.equippedCosmetic.rawValue)
    }

    static func person(from payload: PingPayload) -> PersonRef? {
        guard let uid = payload.uid, !uid.isEmpty, let handle = payload.handle else { return nil }
        let color = payload.color.flatMap(IdentityColor.init(rawValue:)) ?? IdentityColor.stable(for: uid)
        let avatar = payload.avatar.flatMap(AvatarSpec.init(compact:)) ?? AvatarSpec()
        let cosmetic = payload.cosmetic.flatMap(CosmeticID.init(rawValue:)) ?? .classic
        return PersonRef(id: uid, handle: HandleRules.normalize(handle), avatar: avatar, color: color, cosmetic: cosmetic)
    }

    // MARK: - Routing

    struct Route: Hashable {
        var to: InboxToken
        var from: InboxToken?
        var key: String
    }

    /// How to reach `uid` about something happening in `zone`: through the group channel when the
    /// zone is a group they're in, otherwise through our friendship.
    static func route(to uid: UserID, zone: ZoneRef?, store: Store) -> Route? {
        if let zone = zone, let z = store.cache.zones[zone], let info = z.group,
           let member = z.members[uid],
           let link = store.my.groupLinks.values.first(where: { $0.zone == zone }) {
            return Route(to: member.inbox, from: link.myInbox, key: info.key)
        }
        if let link = store.friendLink(for: uid), link.status == .active, let inbox = link.theirInbox {
            return Route(to: inbox, from: nil, key: link.pairKey)
        }
        return nil
    }

    // MARK: - Intents -> pings

    public static func pings(for intent: PingIntent, store: Store, now: Date) -> [OutgoingPing] {
        guard let me = store.userID else { return [] }
        var out: [OutgoingPing] = []
        var seen = Set<InboxToken>()
        func add(_ r: Route, kind: PingKind, payload: PingPayload, eventID: UUID? = nil) {
            guard !seen.contains(r.to) else { return }
            seen.insert(r.to)
            out.append(OutgoingPing(to: r.to, kind: kind, from: r.from, payload: payload, key: r.key, eventID: eventID, expiresAt: now.addingTimeInterval(kind.lifetime)))
        }

        switch intent {
        case .poop(let eventID, let kind):
            guard let e = store.my.events[eventID], e.source != .manual else { return [] }
            let payload = PingPayload(at: e.startedAt)
            let friendIDs = Set(store.activeFriendLinks.compactMap { $0.userID })
            for link in store.activeFriendLinks {
                guard let inbox = link.theirInbox else { continue }
                add(Route(to: inbox, from: nil, key: link.pairKey), kind: kind, payload: payload, eventID: eventID)
            }
            guard e.sharedToGroups else { break }
            for link in store.my.groupLinks.values.sorted(by: { $0.joinedAt < $1.joinedAt }) where link.shareEvents {
                guard let z = store.cache.zones[link.zone], let info = z.group else { continue }
                var gp = payload
                gp.groupID = info.id.uuidString
                for member in z.members.values.sorted(by: { $0.joinedAt < $1.joinedAt }) {
                    // Friends already got the friend ping; never notify the same person twice.
                    if member.id == me || friendIDs.contains(member.id) { continue }
                    add(Route(to: member.inbox, from: link.myInbox, key: info.key), kind: kind, payload: gp, eventID: eventID)
                }
            }

        case .pwmInvite(let zone, let sessionID, let invitees):
            var payload = PingPayload(sessionID: sessionID.uuidString)
            payload.uid = me
            payload.handle = store.profile.handle
            if let g = store.cache.zones[zone]?.group { payload.groupID = g.id.uuidString } else { payload.shareURL = store.my.spaceLinks[zone]?.shareURL }
            for uid in invitees where uid != me {
                if let r = route(to: uid, zone: zone, store: store) { add(r, kind: .pwmInvite, payload: payload) }
            }

        case .pwmJoin(let zone, let sessionID):
            guard let z = store.cache.zones[zone] else { break }
            var payload = PingPayload(sessionID: sessionID.uuidString)
            if let g = z.group { payload.groupID = g.id.uuidString }
            var recipients = Set<UserID>()
            if let s = z.sessions[sessionID] { recipients.insert(s.creatorID) }
            for p in (z.participants[sessionID] ?? [:]).values where p.status == .joined { recipients.insert(p.id) }
            recipients.remove(me)
            for uid in recipients.sorted() {
                if let r = route(to: uid, zone: zone, store: store) { add(r, kind: .pwmJoin, payload: payload) }
            }

        case .partyInvite(let zone, let partyID, let invitees):
            guard let party = store.cache.zones[zone]?.parties[partyID] else { break }
            var payload = PingPayload(partyID: partyID.uuidString, title: party.title, at: party.scheduledAt)
            if let g = store.cache.zones[zone]?.group { payload.groupID = g.id.uuidString } else { payload.shareURL = store.my.spaceLinks[zone]?.shareURL }
            // Party invites stay relevant until shortly after the party starts.
            let expiry = max(now.addingTimeInterval(3600), party.scheduledAt.addingTimeInterval(3600))
            for uid in invitees where uid != me {
                guard let r = route(to: uid, zone: zone, store: store), !seen.contains(r.to) else { continue }
                seen.insert(r.to)
                out.append(OutgoingPing(to: r.to, kind: .partyInvite, from: r.from, payload: payload, key: r.key, eventID: nil, expiresAt: expiry))
            }
        }
        return out
    }

    // MARK: - Friend handshake pings

    /// B -> A: "I scanned your invite." Sealed with the invite secret.
    public static func friendRequest(invite: FriendInvitePayload, link: FriendLink, store: Store, now: Date) -> OutgoingPing {
        var payload = identity(store)
        payload.inbox = link.myInbox
        payload.pairKey = link.pairKey
        return OutgoingPing(to: invite.t, kind: .friendRequest, from: nil, payload: payload, key: invite.k, eventID: nil, expiresAt: now.addingTimeInterval(PingKind.friendRequest.lifetime))
    }

    /// A -> B: "Accepted. Here's my history." Sealed with the pair key B generated.
    public static func friendAccept(link: FriendLink, shareURL: String, store: Store, now: Date) -> OutgoingPing? {
        guard let inbox = link.theirInbox else { return nil }
        var payload = identity(store)
        payload.inbox = link.myInbox
        payload.shareURL = shareURL
        return OutgoingPing(to: inbox, kind: .friendAccept, from: nil, payload: payload, key: link.pairKey, eventID: nil, expiresAt: now.addingTimeInterval(PingKind.friendAccept.lifetime))
    }

    /// B -> A: "Here's mine." Completes the two-way share.
    public static func friendComplete(link: FriendLink, shareURL: String, store: Store, now: Date) -> OutgoingPing? {
        guard let inbox = link.theirInbox else { return nil }
        var payload = identity(store)
        payload.shareURL = shareURL
        return OutgoingPing(to: inbox, kind: .friendComplete, from: nil, payload: payload, key: link.pairKey, eventID: nil, expiresAt: now.addingTimeInterval(PingKind.friendComplete.lifetime))
    }

    // MARK: - Subscriptions

    /// Kinds each of my inbox tokens should alert for, given notification preferences.
    public static func alertKinds(store: Store, now: Date) -> [InboxToken: Set<PingKind>] {
        let s = store.settings
        var social = Set<PingKind>()
        if s.notifyPWM { social.formUnion(PingKind.pwmKinds) }
        if s.notifyParties { social.formUnion(PingKind.partyKinds) }
        let poops: Set<PingKind> = s.notifyFriendPoops ? Set(PingKind.poopKinds) : []

        var out: [InboxToken: Set<PingKind>] = [:]
        for inv in store.my.invites.values where inv.isValid(now: now) {
            out[inv.token, default: []].insert(.friendRequest)
        }
        for link in store.my.friendLinks.values {
            switch link.status {
            case .requested:
                out[link.myInbox, default: []].insert(.friendAccept)
            case .awaitingTheirShare:
                out[link.myInbox, default: []].insert(.friendComplete)
            case .active:
                switch link.notify {
                case .every: out[link.myInbox, default: []].formUnion(poops.union(social))
                case .pwmOnly: out[link.myInbox, default: []].formUnion(social)
                case .off: break
                }
            }
        }
        for link in store.my.groupLinks.values {
            switch link.notify {
            case .all: out[link.myInbox, default: []].formUnion(poops.union(social))
            case .pwmAndParties: out[link.myInbox, default: []].formUnion(social)
            case .highlightsOnly, .off: break
            }
        }
        return out.filter { !$0.value.isEmpty }
    }

    /// Desired subscriptions: tokens grouped by identical kind sets, chunked, with stable ids.
    public static func subscriptionSpecs(store: Store, now: Date) -> [SubscriptionSpec] {
        let kinds = alertKinds(store: store, now: now)
        var byKinds: [[PingKind]: [InboxToken]] = [:]
        for (token, set) in kinds {
            let ordered = PingKind.allCases.filter { set.contains($0) }
            byKinds[ordered, default: []].append(token)
        }
        var out: [SubscriptionSpec] = []
        for (ks, tokens) in byKinds {
            let code = ks.map { kindCode($0) }.joined()
            let sorted = tokens.sorted()
            var index = 0
            var start = 0
            while start < sorted.count {
                let chunk = Array(sorted[start..<min(start + tokensPerSubscription, sorted.count)])
                out.append(SubscriptionSpec(id: "\(SubscriptionSpec.idPrefix)\(code).\(index)", tokens: chunk, kinds: ks))
                index += 1
                start += tokensPerSubscription
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    static func kindCode(_ k: PingKind) -> String {
        switch k {
        case .poopStart: return "s"
        case .poopInstant: return "i"
        case .pwmInvite: return "w"
        case .pwmJoin: return "j"
        case .partyInvite: return "p"
        case .friendRequest: return "r"
        case .friendAccept: return "a"
        case .friendComplete: return "c"
        }
    }

    /// Every token I might receive pings on (for fetching, regardless of alert preferences).
    public static func listeningTokens(store: Store, now: Date) -> [InboxToken] {
        var t = Set<InboxToken>()
        for inv in store.my.invites.values where inv.isValid(now: now) { t.insert(inv.token) }
        for l in store.my.friendLinks.values { t.insert(l.myInbox) }
        for l in store.my.groupLinks.values { t.insert(l.myInbox) }
        return t.sorted()
    }

    // MARK: - Directory for the Notification Service Extension

    public static func directory(store: Store, now: Date) -> PingDirectory {
        let s = store.settings
        var d = PingDirectory(lockScreenPrivate: s.lockScreenPrivate, quietHoursEnabled: s.quietHoursEnabled, quietStartMinutes: s.quietStartMinutes, quietEndMinutes: s.quietEndMinutes, updatedAt: now)
        for inv in store.my.invites.values where inv.isValid(now: now) {
            d.entries[inv.token] = PingDirectory.Entry(kind: .invite, title: "", key: inv.secret)
        }
        for link in store.my.friendLinks.values {
            let handle = link.userID.flatMap { store.cache.friends[$0]?.profile?.handle } ?? link.person?.handle ?? ""
            d.entries[link.myInbox] = PingDirectory.Entry(kind: .friend, title: handle, key: link.pairKey, muted: link.notify == .off)
        }
        for g in store.groupSummaries {
            var members: [String: String] = [:]
            for m in g.members where m.id != store.userID {
                members[m.inbox] = g.labels[m.id] ?? "@" + m.person.handle
            }
            let muted = g.link.notify == .off || g.link.notify == .highlightsOnly
            d.entries[g.link.myInbox] = PingDirectory.Entry(kind: .group, title: g.name, members: members, key: g.info?.key, muted: muted)
        }
        return d
    }

    // MARK: - Incoming

    public static func process(_ ping: IncomingPing, store: Store, sealer: PayloadSealer, now: Date) -> PingAction {
        if ping.expiresAt < now { return .ignore("expired") }
        let my = store.my

        // An answer to one of my invites.
        if let invite = my.invites[ping.to] {
            guard ping.kind == .friendRequest, invite.isValid(now: now) else { return .ignore("invite token misuse") }
            guard let ref = ping.ref, let payload = try? sealer.openPayload(ref, keyBase64URL: invite.secret) else { return .ignore("undecryptable request") }
            guard let person = person(from: payload), person.id != store.userID,
                  let inbox = payload.inbox, let pairKey = payload.pairKey else { return .ignore("incomplete request") }
            return .friendRequest(IncomingFriendRequest(id: ping.recordName, inviteToken: ping.to, person: person, theirInbox: inbox, pairKey: pairKey, receivedAt: ping.createdAt ?? now))
        }

        // Friend channel.
        if let link = my.friendLinks.values.first(where: { $0.myInbox == ping.to }) {
            let payload = ping.ref.flatMap { try? sealer.openPayload($0, keyBase64URL: link.pairKey) }
            switch ping.kind {
            case .friendAccept:
                guard link.status == .requested else { return .ignore("not waiting for accept") }
                guard let p = payload, let person = person(from: p), person.id != store.userID,
                      let inbox = p.inbox, let url = p.shareURL else { return .ignore("incomplete accept") }
                return .friendAccepted(linkID: link.id, person: person, theirInbox: inbox, shareURL: url)
            case .friendComplete:
                guard link.status == .awaitingTheirShare else { return .ignore("not waiting for complete") }
                guard let p = payload, let url = p.shareURL else { return .ignore("incomplete complete") }
                if let uid = p.uid, let expected = link.userID, uid != expected { return .ignore("sender mismatch") }
                return .friendCompleted(linkID: link.id, shareURL: url)
            case .pwmInvite:
                guard link.status == .active, let p = payload, let sid = p.sessionID.flatMap(UUID.init(uuidString:)) else { return .ignore("bad pwm invite") }
                return .pwmInvite(sessionID: sid, groupID: p.groupID.flatMap(UUID.init(uuidString:)), shareURL: p.shareURL)
            case .partyInvite:
                guard link.status == .active, let p = payload, let pid = p.partyID.flatMap(UUID.init(uuidString:)) else { return .ignore("bad party invite") }
                return .partyInvite(partyID: pid, groupID: p.groupID.flatMap(UUID.init(uuidString:)), shareURL: p.shareURL)
            case .poopStart, .poopInstant, .pwmJoin:
                return link.status == .active ? .refreshShared : .ignore("not active")
            case .friendRequest:
                return .ignore("request on friend channel")
            }
        }

        // Group channel.
        if let link = my.groupLinks.values.first(where: { $0.myInbox == ping.to }) {
            let key = store.cache.zones[link.zone]?.group?.key
            let payload = key.flatMap { k in ping.ref.flatMap { try? sealer.openPayload($0, keyBase64URL: k) } }
            switch ping.kind {
            case .pwmInvite:
                guard let p = payload, let sid = p.sessionID.flatMap(UUID.init(uuidString:)) else { return .refreshShared }
                return .pwmInvite(sessionID: sid, groupID: link.id, shareURL: nil)
            case .partyInvite:
                guard let p = payload, let pid = p.partyID.flatMap(UUID.init(uuidString:)) else { return .refreshShared }
                return .partyInvite(partyID: pid, groupID: link.id, shareURL: nil)
            case .poopStart, .poopInstant, .pwmJoin:
                return .refreshShared
            case .friendRequest, .friendAccept, .friendComplete:
                return .ignore("handshake on group channel")
            }
        }
        return .ignore("unknown token")
    }
}
