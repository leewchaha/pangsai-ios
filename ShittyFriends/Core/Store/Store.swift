import Foundation
import Observation

public enum DirtyPart: Sendable { case my, cache }

public struct UndoToken: Hashable, Sendable {
    public var eventID: UUID
    public var source: PoopSource
    public var at: Date
}

public struct FriendSummary: Hashable, Identifiable {
    public var link: FriendLink
    public var person: PersonRef
    public var todayCount: Int
    public var live: PoopEvent?
    public var lastEvent: PoopEvent?
    public var hasHistory: Bool

    public var id: UUID { link.id }
}

public struct GroupSummary: Hashable, Identifiable {
    public var link: GroupLink
    public var info: GroupInfo?
    public var members: [GroupMember]
    public var labels: [UserID: String]

    public var id: UUID { link.id }
    public var name: String { info?.name ?? link.nameCache }
    public var color: IdentityColor { info?.color ?? .violet }
    public var object: GroupObject { info?.object ?? .toilet }
}

public struct LiveSessionView: Hashable, Identifiable {
    public var zone: ZoneRef
    public var session: PWMSession
    public var participants: [PWMParticipant]
    public var groupName: String?

    public var id: UUID { session.id }
}

public struct PartyView: Hashable, Identifiable {
    public var zone: ZoneRef
    public var party: Party
    public var rsvps: [PartyRSVP]
    public var groupName: String?

    public var id: UUID { party.id }
}

/// The local-first source of truth. Every user action mutates this synchronously (so +1 is instant)
/// and emits `Effect`s that the platform layer turns into CloudKit writes, pings, notifications, haptics.
@Observable
public final class Store {
    public internal(set) var my: MyState
    public internal(set) var cache: CacheState
    /// Most recent log, for the short-lived Undo.
    public internal(set) var undo: UndoToken?
    /// Bumped on every tap so views can animate.
    public internal(set) var tapPulse: Int = 0
    public internal(set) var lastTap: TapOutcome?

    @ObservationIgnored public var effectHandler: ((Effect) -> Void)?
    @ObservationIgnored public var onDirty: ((DirtyPart) -> Void)?
    @ObservationIgnored public var clock: () -> Date = { Date() }
    @ObservationIgnored public var calendar: Calendar = CalendarMath.standard()
    @ObservationIgnored public var rules: PointRules = .standard
    @ObservationIgnored public var randomRoll: () -> Double = { Double.random(in: 0..<1) }
    @ObservationIgnored var tapState = TapState()

    public static let undoWindow: TimeInterval = 6
    public static let sessionWindow: TimeInterval = 3 * 3600

    public init(my: MyState = MyState(), cache: CacheState = CacheState()) {
        self.my = my
        self.cache = cache
    }

    // MARK: - Plumbing

    func emit(_ effects: [Effect]) {
        guard let handler = effectHandler else { return }
        for e in effects { handler(e) }
    }

    func dirty(_ part: DirtyPart = .my) { onDirty?(part) }

    func mutateMy(_ body: (inout MyState) -> Void) {
        body(&my)
        dirty(.my)
    }

    func mutateCache(_ body: (inout CacheState) -> Void) {
        body(&cache)
        dirty(.cache)
    }

    /// Replace everything (used after loading from disk or when the iCloud account changes).
    public func replaceAll(my: MyState, cache: CacheState) {
        self.my = my
        self.cache = cache
    }

    // MARK: - Identity

    public var userID: UserID? { my.userID }
    public var profile: UserProfile { my.profile ?? .placeholder }
    public var meRef: PersonRef { PersonRef(id: my.userID ?? .localMe, profile: profile) }
    public var settings: AppSettings { my.settings }

    public func setUserID(_ id: UserID?) {
        guard my.userID != id else { return }
        mutateMy { $0.userID = id }
        emit([.refreshSubscriptions, .refreshDirectory])
    }

    public func confirmAge() { mutateMy { $0.ageConfirmed = true } }

    public func completeOnboarding(handle: String, avatar: AvatarSpec, color: IdentityColor) {
        let now = clock()
        mutateMy {
            $0.profile = UserProfile(handle: HandleRules.normalize(handle), avatar: avatar, color: color, equippedCosmetic: $0.profile?.equippedCosmetic ?? .classic, createdAt: $0.profile?.createdAt ?? now, updatedAt: now)
            $0.onboarded = true
        }
        emit([.save(.profile)])
    }

    /// Onboarding: store the profile so invites can use it, without finishing onboarding yet.
    public func saveProfileDraft(handle: String, avatar: AvatarSpec, color: IdentityColor) {
        let now = clock()
        mutateMy {
            $0.profile = UserProfile(handle: HandleRules.normalize(handle), avatar: avatar, color: color, equippedCosmetic: $0.profile?.equippedCosmetic ?? .classic, createdAt: $0.profile?.createdAt ?? now, updatedAt: now)
        }
        emit([.save(.profile)])
    }

    public func updateProfile(handle: String? = nil, avatar: AvatarSpec? = nil, color: IdentityColor? = nil) {
        guard var p = my.profile else { return }
        if let h = handle { p.handle = HandleRules.normalize(h) }
        if let a = avatar { p.avatar = a }
        if let c = color { p.color = c }
        p.updatedAt = clock()
        mutateMy { $0.profile = p }
        var effects: [Effect] = [.save(.profile)]
        effects += refreshMyMemberRecords()
        emit(effects)
    }

    /// Re-saves my member/participant identity in every group so handle/avatar changes propagate.
    func refreshMyMemberRecords() -> [Effect] {
        guard let uid = my.userID else { return [] }
        var effects: [Effect] = []
        let me = meRef
        mutateCache { c in
            for (zone, var z) in c.zones {
                if var m = z.members[uid] {
                    m.person = me
                    m.updatedAt = self.clock()
                    z.members[uid] = m
                    c.zones[zone] = z
                    effects.append(.save(.member(zone, uid)))
                }
            }
        }
        return effects
    }

    // MARK: - Settings

    public func updateSettings(_ body: (inout AppSettings) -> Void) {
        var s = my.settings
        body(&s)
        s.updatedAt = clock()
        mutateMy { $0.settings = s }
        emit([.save(.settings), .refreshSubscriptions, .refreshDirectory, .rescheduleSummaries])
    }

    // MARK: - Derived: my history

    public var sortedEvents: [PoopEvent] {
        my.events.values.sorted { $0.startedAt > $1.startedAt }
    }

    public var liveEvent: PoopEvent? {
        my.events.values.filter { $0.isLive }.max(by: { $0.startedAt < $1.startedAt })
    }

    public func todayCount(now: Date? = nil) -> Int {
        let day = DayKey(now ?? clock(), calendar: calendar)
        return my.events.values.filter { DayKey($0.startedAt, calendar: calendar) == day }.count
    }

    public func events(on day: DayKey) -> [PoopEvent] {
        my.events.values.filter { DayKey($0.startedAt, calendar: calendar) == day }.sorted { $0.startedAt < $1.startedAt }
    }

    public var pointsBalance: Int {
        PointsEngine.balance(events: Array(my.events.values), unlocks: Array(my.cosmetics.values))
    }

    public var lifetimePoints: Int { PointsEngine.lifetimePoints(events: Array(my.events.values)) }

    public func stats(in interval: DateInterval? = nil) -> PoopStats {
        StatsCalculator.compute(Array(my.events.values), in: interval, now: clock(), calendar: calendar)
    }

    // MARK: - Derived: friends

    public var activeFriendLinks: [FriendLink] {
        my.friendLinks.values.filter { $0.status == .active && $0.userID != nil }.sorted { ($0.person?.handle ?? "") < ($1.person?.handle ?? "") }
    }

    public var pendingFriendLinks: [FriendLink] {
        my.friendLinks.values.filter { $0.status != .active }.sorted { $0.createdAt > $1.createdAt }
    }

    public func friendLink(for userID: UserID) -> FriendLink? {
        my.friendLinks.values.first { $0.userID == userID }
    }

    public func isFriend(_ userID: UserID) -> Bool {
        friendLink(for: userID)?.status == .active
    }

    public func person(for userID: UserID) -> PersonRef? {
        if userID == my.userID { return meRef }
        if let p = cache.friends[userID]?.profile { return PersonRef(id: userID, profile: p) }
        if let p = friendLink(for: userID)?.person { return p }
        for z in cache.zones.values {
            if let m = z.members[userID] { return m.person }
        }
        for z in cache.zones.values {
            for ps in z.participants.values { if let p = ps[userID] { return p.person } }
        }
        return nil
    }

    public func friendSummaries(now: Date? = nil) -> [FriendSummary] {
        let n = now ?? clock()
        let day = DayKey(n, calendar: calendar)
        return activeFriendLinks.compactMap { link in
            guard let uid = link.userID else { return nil }
            let fc = cache.friends[uid]
            let person = fc?.profile.map { PersonRef(id: uid, profile: $0) } ?? link.person ?? PersonRef(id: uid, handle: "friend", avatar: AvatarSpec(), color: IdentityColor.stable(for: uid))
            let events = fc.map { Array($0.events.values) } ?? []
            let today = events.filter { DayKey($0.startedAt, calendar: calendar) == day }.count
            return FriendSummary(link: link, person: person, todayCount: today, live: fc?.liveEvent, lastEvent: events.max(by: { $0.startedAt < $1.startedAt }), hasHistory: fc != nil)
        }
    }

    public func friendEvents(_ userID: UserID) -> [PoopEvent] {
        (cache.friends[userID].map { Array($0.events.values) } ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Derived: groups

    public var groupSummaries: [GroupSummary] {
        my.groupLinks.values.sorted { $0.joinedAt < $1.joinedAt }.map { link in
            let z = cache.zones[link.zone]
            let members = (z.map { Array($0.members.values) } ?? []).sorted { $0.joinedAt < $1.joinedAt }
            let labels = HandleRules.groupLabels(members.map { ($0.id, $0.person.handle, $0.joinedAt) })
            return GroupSummary(link: link, info: z?.group, members: members, labels: labels)
        }
    }

    public func group(_ id: UUID) -> GroupSummary? { groupSummaries.first { $0.link.id == id } }

    public func groupEvents(_ zone: ZoneRef) -> [GroupEvent] {
        (cache.zones[zone].map { Array($0.events.values) } ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    /// Weekly leaderboard for a group: (member, count), highest first, ties by handle.
    public func leaderboard(_ zone: ZoneRef, period: HighlightPeriod = .week, now: Date? = nil) -> [(member: GroupMember, count: Int)] {
        guard let z = cache.zones[zone] else { return [] }
        let interval = period.interval(containing: now ?? clock(), calendar: calendar)
        var counts: [UserID: Int] = [:]
        for e in z.events.values where interval.contains(e.startedAt) { counts[e.ownerID, default: 0] += 1 }
        return z.members.values.map { ($0, counts[$0.id] ?? 0) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.member.person.handle.lowercased() < $1.member.person.handle.lowercased()
        }
    }

    // MARK: - Derived: live sessions & parties

    func groupName(for zone: ZoneRef) -> String? {
        cache.zones[zone]?.group?.name ?? my.groupLinks.values.first(where: { $0.zone == zone })?.nameCache
    }

    /// Open Poop With Me sessions I'm part of (invited or joined), newest first.
    public func liveSessions(now: Date? = nil) -> [LiveSessionView] {
        let n = now ?? clock()
        guard let uid = my.userID else { return [] }
        var out: [LiveSessionView] = []
        for (zone, z) in cache.zones {
            for s in z.sessions.values where s.state == .open && n.timeIntervalSince(s.createdAt) < Store.sessionWindow {
                let ps = Array((z.participants[s.id] ?? [:]).values)
                guard ps.contains(where: { $0.id == uid }) || s.creatorID == uid else { continue }
                let sorted = ps.sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
                out.append(LiveSessionView(zone: zone, session: s, participants: sorted, groupName: groupName(for: zone)))
            }
        }
        return out.sorted { $0.session.createdAt > $1.session.createdAt }
    }

    public func liveSession(_ id: UUID) -> LiveSessionView? {
        liveSessions().first { $0.session.id == id }
    }

    /// Sessions where I'm invited but haven't joined yet.
    public func pendingInvites(now: Date? = nil) -> [LiveSessionView] {
        guard let uid = my.userID else { return [] }
        return liveSessions(now: now).filter { v in
            v.participants.first(where: { $0.id == uid })?.status == .invited
        }
    }

    public func parties(now: Date? = nil, includePast: Bool = false) -> [PartyView] {
        let n = now ?? clock()
        var out: [PartyView] = []
        for (zone, z) in cache.zones {
            for p in z.parties.values {
                if !includePast && p.isOver(now: n) { continue }
                let rs = Array((z.rsvps[p.id] ?? [:]).values).sorted { $0.person.handle.lowercased() < $1.person.handle.lowercased() }
                out.append(PartyView(zone: zone, party: p, rsvps: rs, groupName: groupName(for: zone)))
            }
        }
        return out.sorted { $0.party.scheduledAt < $1.party.scheduledAt }
    }

    public func party(_ id: UUID) -> PartyView? { parties(includePast: true).first { $0.party.id == id } }

    public func myRSVP(_ party: PartyView) -> PartyRSVP? {
        guard let uid = my.userID else { return nil }
        return party.rsvps.first { $0.id == uid }
    }

    // MARK: - Achievements

    func achievementContext() -> AchievementContext {
        let n = clock()
        var pastYes: [(partyID: UUID, scheduledAt: Date, joined: Bool)] = []
        let myPartyIDs = Set(my.events.values.compactMap { $0.partyID })
        if let uid = my.userID {
            for z in cache.zones.values {
                for p in z.parties.values where p.status == .scheduled && p.scheduledAt < n {
                    if z.rsvps[p.id]?[uid]?.response == .yes {
                        pastYes.append((p.id, p.scheduledAt, myPartyIDs.contains(p.id)))
                    }
                }
            }
        }
        return AchievementContext(
            events: Array(my.events.values),
            friendCount: activeFriendLinks.count,
            completedSocialSessions: my.confirmedSocialSessions.count,
            pastYesParties: pastYes,
            ownedCosmetics: ownedCosmetics.count,
            now: n,
            calendar: calendar
        )
    }

    public func achievementProgress(_ id: AchievementID) -> AchievementProgress? {
        AchievementEngine.progress(id, achievementContext())
    }

    /// Evaluates and records any newly earned achievements.
    @discardableResult
    public func evaluateAchievements() -> [AchievementID] {
        let new = AchievementEngine.newlyUnlocked(achievementContext(), already: Set(my.achievements.keys))
        guard !new.isEmpty else { return [] }
        mutateMy { m in for a in new { m.achievements[a.id] = a } }
        emit(new.map { .save(.achievement($0.id)) } + [.achievementsUnlocked(new.map { $0.id })])
        return new.map { $0.id }
    }

    // MARK: - Cosmetics

    public var ownedCosmetics: [CosmeticID] {
        var owned: Set<CosmeticID> = [.classic]
        owned.formUnion(my.cosmetics.keys)
        return CosmeticID.allCases.filter { owned.contains($0) }
    }

    public enum PurchaseError: Error, Equatable { case alreadyOwned, insufficientPoints(needed: Int) }

    public func purchase(_ id: CosmeticID) throws {
        if ownedCosmetics.contains(id) { throw PurchaseError.alreadyOwned }
        let balance = pointsBalance
        guard balance >= id.price else { throw PurchaseError.insufficientPoints(needed: id.price - balance) }
        mutateMy { $0.cosmetics[id] = CosmeticUnlock(id: id, unlockedAt: self.clock(), cost: id.price) }
        emit([.save(.cosmetic(id)), .cosmeticUnlocked(id), .haptic(.success)])
        evaluateAchievements()
    }

    public func equip(_ id: CosmeticID) {
        guard ownedCosmetics.contains(id), var p = my.profile else { return }
        p.equippedCosmetic = id
        p.updatedAt = clock()
        mutateMy { $0.profile = p }
        var effects: [Effect] = [.save(.profile)]
        effects += refreshMyMemberRecords()
        emit(effects)
    }
}
