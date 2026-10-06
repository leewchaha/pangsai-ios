import Foundation

public extension Store {
    /// Applies records fetched from CloudKit (my other devices, friends' zones, groups, sessions).
    func apply(_ changes: [RemoteChange]) {
        guard !changes.isEmpty else { return }
        var effects: [Effect] = []
        var touchedSessions: [(ZoneRef, UUID)] = []
        var linksChanged = false
        var directoryChanged = false

        for change in changes {
            switch change {
            case .upsert(let record, let zone):
                if zone.isMine && (zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private) {
                    linksChanged = applyMine(record) || linksChanged
                } else if !zone.isMine && zone.zoneName == ZoneNames.me {
                    applyFriend(record, ownerID: zone.ownerName, zone: zone)
                } else {
                    let r = applyZone(record, zone: zone)
                    if let s = r.session { touchedSessions.append((zone, s)) }
                    directoryChanged = directoryChanged || r.directory
                    effects += r.effects
                }
            case .delete(let ref, let zone):
                linksChanged = applyDelete(ref, zone: zone) || linksChanged
            case .zoneDeleted(let zone):
                effects += applyZoneDeleted(zone)
                linksChanged = true
            }
        }

        for (zone, sid) in touchedSessions {
            confirmSocialSession(zone: zone, sessionID: sid)
            effects += maybeEndSession(zone: zone, sessionID: sid)
        }
        if linksChanged || directoryChanged { effects += [.refreshSubscriptions, .refreshDirectory] }
        emit(effects)
        evaluateAchievements()
    }

    // MARK: - Mine (from my other devices)

    /// Returns true if links/settings changed (subscriptions need refreshing).
    private func applyMine(_ record: RemoteRecord) -> Bool {
        switch record {
        case .profile(let p):
            if (my.profile?.updatedAt ?? .distantPast) <= p.updatedAt {
                mutateMy { $0.profile = p; $0.onboarded = true }
            }
        case .event(let e):
            if let local = my.events[e.id], local.updatedAt > e.updatedAt { return false }
            // Keep locally accumulated taps if this device is running the session.
            var incoming = e
            if let local = my.events[e.id], local.isLive, incoming.isLive {
                incoming.taps = max(local.taps, incoming.taps)
                incoming.halfPoints = max(local.halfPoints, incoming.halfPoints)
            }
            mutateMy { $0.events[e.id] = incoming }
        case .achievement(let a):
            if my.achievements[a.id] == nil { mutateMy { $0.achievements[a.id] = a } }
        case .cosmetic(let c):
            mutateMy { $0.cosmetics[c.id] = c }
        case .settings(let s):
            if my.settings.updatedAt <= s.updatedAt { mutateMy { $0.settings = s }; return true }
        case .friendLink(let l):
            if let local = my.friendLinks[l.id], local.updatedAt > l.updatedAt { return false }
            mutateMy { $0.friendLinks[l.id] = l }
            return true
        case .groupLink(let l):
            if let local = my.groupLinks[l.id], local.updatedAt > l.updatedAt { return false }
            mutateMy { $0.groupLinks[l.id] = l }
            mutateCache { c in if c.zones[l.zone] == nil { c.zones[l.zone] = ZoneCache(zone: l.zone) } }
            return true
        case .invite(let i):
            mutateMy { $0.invites[i.token] = i }
            return true
        case .spaceLink(let s):
            mutateMy { $0.spaceLinks[s.zone] = s }
        default:
            break
        }
        return false
    }

    // MARK: - Friends' Me zones

    private func applyFriend(_ record: RemoteRecord, ownerID: UserID, zone: ZoneRef) {
        mutateCache { c in
            var fc = c.friends[ownerID] ?? FriendCache(userID: ownerID, zone: zone)
            switch record {
            case .profile(let p): fc.profile = p
            case .event(let e): fc.events[e.id] = e
            case .achievement(let a): fc.achievements[a.id] = a
            case .cosmetic(let x): fc.cosmetics[x.id] = x
            default: break
            }
            fc.lastFetchedAt = self.clock()
            c.friends[ownerID] = fc
        }
        // Keep the link's cached identity fresh.
        if case .profile(let p) = record, var link = friendLink(for: ownerID) {
            let ref = PersonRef(id: ownerID, profile: p)
            if link.person != ref {
                link.person = ref
                mutateMy { $0.friendLinks[link.id] = link }
                emit([.refreshDirectory])
            }
        }
    }

    // MARK: - Group / session zones

    private func applyZone(_ record: RemoteRecord, zone: ZoneRef) -> (session: UUID?, directory: Bool, effects: [Effect]) {
        var session: UUID?
        var directory = false
        var effects: [Effect] = []
        let uid = my.userID
        var z = cache.zones[zone] ?? ZoneCache(zone: zone)
        switch record {
        case .groupInfo(let g):
            z.group = g
            directory = true
            if var link = my.groupLinks[g.id], link.nameCache != g.name {
                link.nameCache = g.name
                mutateMy { $0.groupLinks[g.id] = link }
            }
        case .member(let m):
            // Never let a stale copy of my own member record overwrite my local one.
            if m.id == uid, let local = z.members[m.id], local.updatedAt > m.updatedAt { break }
            z.members[m.id] = m
            directory = true
        case .groupEvent(let e):
            if e.ownerID == uid, let local = z.events[e.id], local.updatedAt > e.updatedAt { break }
            z.events[e.id] = e
        case .pwmSession(let s):
            if let local = z.sessions[s.id], local.updatedAt > s.updatedAt { break }
            z.sessions[s.id] = s
            session = s.id
        case .participant(let p):
            if p.id == uid, let local = z.participants[p.sessionID]?[p.id], local.updatedAt > p.updatedAt { break }
            z.participants[p.sessionID, default: [:]][p.id] = p
            session = p.sessionID
        case .reaction(let r):
            z.reactions[r.id] = r
        case .party(let p):
            z.parties[p.id] = p
            if p.status == .cancelled {
                effects.append(.cancelParty(partyID: p.id))
            } else if let me = uid, (z.rsvps[p.id]?[me]?.response ?? .maybe) != .no {
                effects.append(.scheduleParty(zone: zone, partyID: p.id))
            }
        case .rsvp(let r):
            if r.id == uid, let local = z.rsvps[r.partyID]?[r.id], local.updatedAt > r.updatedAt { break }
            z.rsvps[r.partyID, default: [:]][r.id] = r
        default:
            break
        }
        let updated = z
        mutateCache { $0.zones[zone] = updated }
        return (session, directory, effects)
    }

    // MARK: - Deletes

    private func applyDelete(_ ref: RecordRef, zone: ZoneRef) -> Bool {
        if !zone.isMine && zone.zoneName == ZoneNames.me {
            let owner = zone.ownerName
            mutateCache { c in
                switch ref {
                case .event(let id): c.friends[owner]?.events[id] = nil
                case .achievement(let id): c.friends[owner]?.achievements[id] = nil
                case .cosmetic(let id): c.friends[owner]?.cosmetics[id] = nil
                case .profile: c.friends[owner]?.profile = nil
                default: break
                }
            }
            return false
        }
        switch ref {
        case .event(let id): mutateMy { $0.events[id] = nil }
        case .achievement(let id): mutateMy { $0.achievements[id] = nil }
        case .cosmetic(let id): mutateMy { $0.cosmetics[id] = nil }
        case .friendLink(let id):
            if let uid = my.friendLinks[id]?.userID { mutateCache { $0.friends[uid] = nil } }
            mutateMy { $0.friendLinks[id] = nil }
            return true
        case .groupLink(let id):
            if let l = my.groupLinks[id] { mutateCache { $0.zones[l.zone] = nil } }
            mutateMy { $0.groupLinks[id] = nil }
            return true
        case .invite(let t):
            mutateMy { $0.invites[t] = nil }
            return true
        case .spaceLink(let z): mutateMy { $0.spaceLinks[z] = nil }
        case .member(let z, let uid): mutateCache { $0.zones[z]?.members[uid] = nil }
        case .groupEvent(let z, let id): mutateCache { $0.zones[z]?.events[id] = nil }
        case .pwmSession(let z, let id): mutateCache { $0.zones[z]?.sessions[id] = nil }
        case .participant(let z, let sid, let uid): mutateCache { $0.zones[z]?.participants[sid]?[uid] = nil }
        case .reaction(let z, let id): mutateCache { $0.zones[z]?.reactions[id] = nil }
        case .party(let z, let id): mutateCache { $0.zones[z]?.parties[id] = nil }
        case .rsvp(let z, let pid, let uid): mutateCache { $0.zones[z]?.rsvps[pid]?[uid] = nil }
        case .profile, .settings, .groupInfo:
            break
        }
        return false
    }

    private func applyZoneDeleted(_ zone: ZoneRef) -> [Effect] {
        var effects: [Effect] = []
        if !zone.isMine && zone.zoneName == ZoneNames.me {
            // A friend removed me (or I left). Friendship is bidirectional, so end it on my side too.
            let owner = zone.ownerName
            mutateCache { $0.friends[owner] = nil }
            if let link = friendLink(for: owner), link.status == .active {
                mutateMy { $0.friendLinks[link.id] = nil }
                effects += [.delete(.friendLink(link.id)), .friendZoneGone(owner)]
            }
            return effects
        }
        archiveSessions(in: zone)
        mutateCache { $0.zones[zone] = nil }
        if let link = my.groupLinks.values.first(where: { $0.zone == zone }) {
            mutateMy { $0.groupLinks[link.id] = nil }
            effects.append(.delete(.groupLink(link.id)))
        }
        if my.spaceLinks[zone] != nil {
            mutateMy { $0.spaceLinks[zone] = nil }
            effects.append(.delete(.spaceLink(zone)))
        }
        return effects
    }

    /// Account switched / signed out: start clean.
    func resetForAccountChange(keepOnboarding: Bool) {
        let profile = keepOnboarding ? my.profile : nil
        var fresh = MyState()
        fresh.profile = profile
        fresh.onboarded = keepOnboarding && profile != nil
        fresh.ageConfirmed = my.ageConfirmed
        replaceAll(my: fresh, cache: CacheState())
        dirty(.my)
        dirty(.cache)
    }
}
