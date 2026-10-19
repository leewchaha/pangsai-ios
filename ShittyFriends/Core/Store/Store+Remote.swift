import Foundation

public extension Store {
    /// Applies records that arrived from the server (my other devices, friends' histories, groups, sessions).
    func apply(_ changes: [RemoteChange]) {
        guard !changes.isEmpty else { return }
        var effects: [Effect] = []
        var touchedSessions: [(ZoneRef, UUID)] = []
        var touchedParties: [(ZoneRef, UUID)] = []
        var linksChanged = false
        var directoryChanged = false

        for change in changes {
            var change = change
            if case .upsertFrom(let record, let zone, let writer) = change {
                if isSharedSpace(zone), !isAllowedWriter(writer, of: record, in: zone) {
                    // Forged or tampered record: ignore it, and put mine back if it was about me.
                    effects += repairEffects(for: record, in: zone)
                    continue
                }
                change = .upsert(record, zone: zone)
            }
            switch change {
            case .upsertFrom:
                break
            case .upsert(let record, let zone):
                if zone.isMine && (zone.zoneName == ZoneNames.me || zone.zoneName == ZoneNames.private) {
                    linksChanged = applyMine(record) || linksChanged
                } else if !zone.isMine && zone.zoneName == ZoneNames.me {
                    applyFriend(record, ownerID: zone.ownerName, zone: zone)
                } else {
                    let r = applyZone(record, zone: zone)
                    if let s = r.session { touchedSessions.append((zone, s)) }
                    if let p = r.party { touchedParties.append((zone, p)) }
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
        for (zone, pid) in touchedParties { confirmSocialParty(zone: zone, partyID: pid) }
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
                // Never erase paid shine ownership when an older client syncs a profile
                // lacking the new fields. Purchases are append-only.
                var incoming = p
                let old = my.profile
                for (id, purchase) in old?.pinShines ?? [:] where incoming.pinShines[id] == nil {
                    incoming.pinShines[id] = purchase
                }
                if p.pinShines.isEmpty, let old, old.equippedPinShine != .classicWhite {
                    incoming.equippedPinShine = old.equippedPinShine
                }
                // Banked points only ever grow: an older client (no field) or a device that hasn't
                // seen a delete yet must not shrink them.
                incoming.bankedHalfPoints = max(incoming.bankedHalfPoints, old?.bankedHalfPoints ?? 0)
                mutateMy { $0.profile = incoming; $0.onboarded = true }
                if incoming != p { emit([.save(.profile)]) }
            } else if var local = my.profile, p.bankedHalfPoints > local.bankedHalfPoints {
                // An older profile can still carry a bank made on another device: keep the larger.
                local.bankedHalfPoints = p.bankedHalfPoints
                local.updatedAt = max(local.updatedAt, clock())
                mutateMy { $0.profile = local }
                emit([.save(.profile)])
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
            if my.settings.updatedAt <= s.updatedAt {
                let newlyBlocked = Set(s.blockedUserIDs).subtracting(my.settings.blockedUserIDs)
                mutateMy { $0.settings = s }
                // A block made on another device drops the friend here too.
                for uid in newlyBlocked {
                    for link in my.friendLinks.values where link.userID == uid { removeFriendLocal(link.id) }
                }
                return true
            }
        case .friendLink(let l):
            if let uid = l.userID, isBlocked(uid) {
                // Blocked here, linked on another device: the block wins everywhere.
                emit([.delete(.friendLink(l.id))])
                return false
            }
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
        guard !isBlocked(ownerID) else { return } // their share may linger; never cache it
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

    // MARK: - Write authority (group / session zones)

    /// Group and Poop With Me / party zones (not anyone's Me or Private zone).
    internal func isSharedSpace(_ zone: ZoneRef) -> Bool {
        zone.zoneName != ZoneNames.me && zone.zoneName != ZoneNames.private
    }

    /// Who may write each record type in a shared space:
    /// - group info: the zone owner
    /// - member: that member (or the zone owner); only the zone owner can be `.owner`
    /// - poop copy, reaction: its owner / sender
    /// - session, party: the creator (a session can also be ended by anyone taking part)
    /// - participant, RSVP: that person, or the creator inviting them
    internal func isAllowedWriter(_ writer: UserID, of record: RemoteRecord, in zone: ZoneRef) -> Bool {
        let owner: UserID? = zone.isMine ? my.userID : zone.ownerName
        let z = cache.zones[zone]
        switch record {
        case .groupInfo:
            return writer == owner
        case .member(let m):
            if m.role == .owner && m.id != owner { return false }
            return writer == m.id || writer == owner
        case .joinRequest(let r):
            return writer == r.id
        case .groupEvent(let e):
            return writer == e.ownerID
        case .reaction(let r):
            return writer == r.senderID
        case .pwmSession(let s):
            if let existing = z?.sessions[s.id], existing.creatorID != s.creatorID { return false }
            if writer == s.creatorID { return true }
            // Others may only mark it ended.
            return s.state == .ended && (z?.participants[s.id]?[writer] != nil || z?.members[writer] != nil)
        case .participant(let p):
            if writer == p.id { return true }
            guard p.status == .invited, p.startedAt == nil else { return false }
            if let s = z?.sessions[p.sessionID] { return writer == s.creatorID }
            return true // session not fetched yet; an invite placeholder is harmless
        case .party(let p):
            if let existing = z?.parties[p.id], existing.creatorID != p.creatorID { return false }
            return writer == p.creatorID
        case .rsvp(let r):
            if writer == r.id { return true }
            guard r.response == .maybe, r.joinedAt == nil else { return false }
            if let p = z?.parties[r.partyID] { return writer == p.creatorID }
            return true
        default:
            return true
        }
    }

    /// After rejecting a forged record: if it impersonated one of mine, re-save my real copy
    /// (or delete the fake when I have no such record).
    internal func repairEffects(for record: RemoteRecord, in zone: ZoneRef) -> [Effect] {
        guard let uid = my.userID else { return [] }
        let z = cache.zones[zone]
        switch record {
        case .groupInfo:
            return zone.isMine && z?.group != nil ? [.save(.groupInfo(zone))] : []
        case .member(let m) where m.id == uid:
            return z?.members[uid] != nil ? [.save(.member(zone, uid))] : []
        case .joinRequest:
            return []
        case .groupEvent(let e) where e.ownerID == uid:
            return z?.events[e.id] != nil ? [.save(.groupEvent(zone, e.id))] : [.delete(.groupEvent(zone, e.id))]
        case .reaction(let r) where r.senderID == uid:
            return z?.reactions[r.id] != nil ? [.save(.reaction(zone, r.id))] : [.delete(.reaction(zone, r.id))]
        case .participant(let p) where p.id == uid:
            return z?.participants[p.sessionID]?[uid] != nil ? [.save(.participant(zone, p.sessionID, uid))] : []
        case .rsvp(let r) where r.id == uid:
            return z?.rsvps[r.partyID]?[uid] != nil ? [.save(.rsvp(zone, r.partyID, uid))] : []
        case .pwmSession(let s):
            if let mine = z?.sessions[s.id], mine.creatorID == uid { return [.save(.pwmSession(zone, s.id))] }
            return []
        case .party(let p):
            if let mine = z?.parties[p.id], mine.creatorID == uid { return [.save(.party(zone, p.id))] }
            return []
        default:
            return []
        }
    }

    /// Run after a full fetch (both databases converged): puts back my member record and my poop
    /// copies in groups if someone deleted them. Done here, not on each delete, so my own deletes
    /// from another device (which can arrive in any order) are never undone.
    func repairMyGroupRecords() {
        guard let uid = my.userID else { return }
        var effects: [Effect] = []
        for link in my.groupLinks.values where link.status == .active {
            guard let z = cache.zones[link.zone], z.group != nil else { continue }
            if z.members[uid] == nil {
                // Only my own row's *contents* are mine to write; the row itself is created by the
                // server on approval (or by me as the owner). Re-saving is harmless either way.
                let role: GroupRole = link.isOwner ? .owner : .member
                let member = GroupMember(person: meRef, role: role, joinedAt: link.joinedAt, updatedAt: clock())
                mutateCache { $0.zones[link.zone]?.members[uid] = member }
                effects.append(.save(.member(link.zone, uid)))
            }
            guard link.shareEvents else { continue }
            for e in my.events.values where e.sharedToGroups && e.startedAt >= link.joinedAt && z.events[e.id] == nil {
                let ge = GroupEvent(event: e, ownerID: uid, includeLocation: link.shareLocations)
                mutateCache { $0.zones[link.zone]?.events[e.id] = ge }
                effects.append(.save(.groupEvent(link.zone, e.id)))
            }
        }
        if !effects.isEmpty { emit(effects + [.refreshDirectory]) }
    }

    // MARK: - Group / session zones

    private func applyZone(_ record: RemoteRecord, zone: ZoneRef) -> (session: UUID?, party: UUID?, directory: Bool, effects: [Effect]) {
        var session: UUID?
        var party: UUID?
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
            if m.id == uid, let gid = zone.groupID, my.groupLinks[gid]?.status == .requested {
                mutateCache { $0.zones[zone] = z }
                groupApproved(gid, joinedAt: m.joinedAt)
                z = cache.zones[zone] ?? z
            }
        case .joinRequest(let r):
            z.requests[r.id] = r
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
            party = r.partyID
        default:
            break
        }
        let updated = z
        mutateCache { $0.zones[zone] = updated }
        return (session, party, directory, effects)
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
        case .spaceLink(let z):
            mutateMy { m in for k in m.spaceLinks.keys where k == z || (k.spaceID != nil && k.spaceID == z.spaceID) { m.spaceLinks[k] = nil } }
        case .member(let z, let uid): mutateCache { $0.zones[z]?.members[uid] = nil }
        case .joinRequest(let z, let uid): mutateCache { $0.zones[z]?.requests[uid] = nil }
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
