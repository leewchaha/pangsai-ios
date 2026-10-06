import Foundation

public extension Store {
    // MARK: - Invites

    /// The invite to show as QR / share. Reuses one with more than a day left.
    func currentInvite() -> OutgoingInvite {
        let now = clock()
        // Drop expired invites first.
        let expired = my.invites.values.filter { !$0.isValid(now: now) }.map { $0.token }
        if !expired.isEmpty {
            mutateMy { m in for t in expired { m.invites[t] = nil } }
            emit(expired.map { .delete(.invite($0)) } + [.refreshSubscriptions, .refreshDirectory])
        }
        if let existing = my.invites.values.filter({ $0.expiresAt.timeIntervalSince(now) > 24 * 3600 }).max(by: { $0.createdAt < $1.createdAt }) {
            return existing
        }
        let invite = OutgoingInvite(createdAt: now)
        mutateMy { $0.invites[invite.token] = invite }
        emit([.save(.invite(invite.token)), .refreshSubscriptions, .refreshDirectory])
        return invite
    }

    func friendInvitePayload() -> FriendInvitePayload {
        let inv = currentInvite()
        return FriendInvitePayload(handle: profile.handle, color: profile.color, avatar: profile.avatar, token: inv.token, secret: inv.secret)
    }

    /// Invalidate every outstanding invite (e.g. a QR was posted publicly by mistake).
    func revokeInvites() {
        let tokens = Array(my.invites.keys)
        mutateMy { $0.invites = [:] }
        emit(tokens.map { .delete(.invite($0)) } + [.refreshSubscriptions, .refreshDirectory])
    }

    func invite(forToken token: String) -> OutgoingInvite? { my.invites[token] }

    /// Records the iCloud link of the invite card once the platform has created it.
    func setInviteShareURL(_ token: String, _ url: String) {
        guard var inv = my.invites[token], inv.shareURL != url else { return }
        inv.shareURL = url
        mutateMy { $0.invites[token] = inv }
        emit([.save(.invite(token))])
    }

    // MARK: - Friend requests (A side: someone answered my invite)

    /// Returns false if ignored (blocked, already a friend, duplicate).
    @discardableResult
    func receiveFriendRequest(_ req: IncomingFriendRequest) -> Bool {
        let uid = req.person.id
        if my.settings.blockedUserIDs.contains(uid) { return false }
        if uid == my.userID { return false }
        if let link = friendLink(for: uid), link.status == .active { return false }
        if my.requests.values.contains(where: { $0.person.id == uid }) {
            // Keep the newest request payload.
            mutateMy { m in
                for (k, v) in m.requests where v.person.id == uid { m.requests[k] = nil }
                m.requests[req.id] = req
            }
            return true
        }
        mutateMy { $0.requests[req.id] = req }
        return true
    }

    var friendRequests: [IncomingFriendRequest] {
        my.requests.values.sorted { $0.receivedAt > $1.receivedAt }
    }

    func dismissRequest(_ id: String) {
        mutateMy { $0.requests[id] = nil }
    }

    // MARK: - Friend links

    /// B side: I answered someone's invite. Creates a pending link I listen on.
    @discardableResult
    func addRequestedLink(invite: FriendInvitePayload, myInbox: InboxToken, pairKey: String) -> FriendLink {
        let now = clock()
        if let existing = my.friendLinks.values.first(where: { $0.inviteToken == invite.t && $0.status == .requested }) {
            return existing
        }
        let person = PersonRef(id: "", handle: invite.h, avatar: invite.avatar, color: invite.color)
        let link = FriendLink(person: person, status: .requested, myInbox: myInbox, pairKey: pairKey, inviteToken: invite.t, createdAt: now, updatedAt: now)
        mutateMy { $0.friendLinks[link.id] = link }
        emit([.save(.friendLink(link.id)), .refreshSubscriptions, .refreshDirectory])
        return link
    }

    func upsertFriendLink(_ link: FriendLink) {
        var l = link
        l.updatedAt = clock()
        mutateMy { m in
            // One link per person.
            if let uid = l.userID {
                for (k, v) in m.friendLinks where v.userID == uid && k != l.id { m.friendLinks[k] = nil }
                for (k, v) in m.requests where v.person.id == uid { m.requests[k] = nil }
            }
            m.friendLinks[l.id] = l
        }
        emit([.save(.friendLink(l.id)), .refreshSubscriptions, .refreshDirectory])
        if l.status == .active { evaluateAchievements() }
    }

    func friendLink(byInbox token: InboxToken) -> FriendLink? {
        my.friendLinks.values.first { $0.myInbox == token }
    }

    /// Removes the friendship locally and purges their cached history.
    func removeFriendLocal(_ linkID: UUID) {
        guard let link = my.friendLinks[linkID] else { return }
        mutateMy { $0.friendLinks[linkID] = nil }
        if let uid = link.userID { mutateCache { $0.friends[uid] = nil } }
        emit([.delete(.friendLink(linkID)), .refreshSubscriptions, .refreshDirectory])
    }

    func setFriendNotify(_ linkID: UUID, _ level: FriendNotifyLevel) {
        guard var l = my.friendLinks[linkID] else { return }
        l.notify = level
        upsertFriendLink(l)
    }

    func block(_ userID: UserID) {
        updateSettings { s in
            if !s.blockedUserIDs.contains(userID) { s.blockedUserIDs.append(userID) }
        }
        mutateMy { m in for (k, v) in m.requests where v.person.id == userID { m.requests[k] = nil } }
    }

    func unblock(_ userID: UserID) {
        updateSettings { $0.blockedUserIDs.removeAll { $0 == userID } }
    }

    func isBlocked(_ userID: UserID) -> Bool { my.settings.blockedUserIDs.contains(userID) }

    /// Cache from a friend's shared Me zone.
    func friendCache(_ userID: UserID) -> FriendCache? { cache.friends[userID] }

    // MARK: - Groups

    /// Creates the local records for a new group I own. The service then creates the zone + share.
    func createGroupLocal(name: String, object: GroupObject, color: IdentityColor) -> GroupLink? {
        guard let uid = my.userID, let clean = ContentFilter.cleanGroupName(name) else { return nil }
        let now = clock()
        let id = UUID()
        let zone = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.group(id))
        let link = GroupLink(id: id, zone: zone, isOwner: true, nameCache: clean, joinedAt: now, updatedAt: now)
        let info = GroupInfo(id: id, name: clean, object: object, color: color, createdBy: uid, createdAt: now, updatedAt: now)
        let member = GroupMember(person: meRef, inbox: link.myInbox, role: .owner, joinedAt: now, updatedAt: now)
        mutateMy { $0.groupLinks[id] = link }
        mutateCache { c in
            var z = ZoneCache(zone: zone)
            z.group = info
            z.members[uid] = member
            c.zones[zone] = z
        }
        var effects: [Effect] = [.ensureZone(zone), .save(.groupLink(id)), .save(.groupInfo(zone)), .save(.member(zone, uid))]
        effects += backfillGroup(link)
        effects += [.refreshSubscriptions, .refreshDirectory]
        emit(effects)
        return link
    }

    /// After accepting a group share: record membership and write my member record.
    @discardableResult
    func registerJoinedGroup(zone: ZoneRef, groupID: UUID, name: String, shareURL: String?) -> GroupLink? {
        guard let uid = my.userID else { return nil }
        if let existing = my.groupLinks[groupID] { return existing }
        let now = clock()
        let link = GroupLink(id: groupID, zone: zone, isOwner: false, shareURL: shareURL, nameCache: name, joinedAt: now, updatedAt: now)
        let member = GroupMember(person: meRef, inbox: link.myInbox, role: .member, joinedAt: now, updatedAt: now)
        mutateMy { $0.groupLinks[groupID] = link }
        mutateCache { c in
            if c.zones[zone] == nil { c.zones[zone] = ZoneCache(zone: zone) }
            c.zones[zone]?.members[uid] = member
        }
        var effects: [Effect] = [.save(.groupLink(groupID)), .save(.member(zone, uid))]
        effects += backfillGroup(link)
        effects += [.refreshSubscriptions, .refreshDirectory]
        emit(effects)
        return link
    }

    /// Mirror my last 31 days into a newly joined group so this week's/month's rankings are meaningful.
    internal func backfillGroup(_ link: GroupLink) -> [Effect] {
        guard let uid = my.userID, link.shareEvents else { return [] }
        let cutoff = clock().addingTimeInterval(-31 * 24 * 3600)
        let recent = my.events.values.filter { $0.startedAt >= cutoff && $0.sharedToGroups }
        guard !recent.isEmpty else { return [] }
        mutateCache { c in
            for e in recent { c.zones[link.zone]?.events[e.id] = GroupEvent(event: e, ownerID: uid, includeLocation: link.shareLocations) }
        }
        return recent.map { .save(.groupEvent(link.zone, $0.id)) }
    }

    func setGroupShareURL(_ groupID: UUID, _ url: String?) {
        guard var l = my.groupLinks[groupID] else { return }
        l.shareURL = url
        l.updatedAt = clock()
        mutateMy { $0.groupLinks[groupID] = l }
        emit([.save(.groupLink(groupID))])
    }

    func setGroupPrefs(_ groupID: UUID, notify: GroupNotifyLevel? = nil, shareEvents: Bool? = nil, shareLocations: Bool? = nil) {
        guard var l = my.groupLinks[groupID] else { return }
        let locationChanged = shareLocations != nil && shareLocations != l.shareLocations
        let sharingChanged = shareEvents != nil && shareEvents != l.shareEvents
        if let n = notify { l.notify = n }
        if let s = shareEvents { l.shareEvents = s }
        if let s = shareLocations { l.shareLocations = s }
        l.updatedAt = clock()
        mutateMy { $0.groupLinks[groupID] = l }
        var effects: [Effect] = [.save(.groupLink(groupID)), .refreshSubscriptions, .refreshDirectory]
        if locationChanged || sharingChanged, let uid = my.userID {
            // Re-mirror (adds/removes locations, or adds/removes events) for my events already in the group.
            let mine = cache.zones[l.zone]?.events.values.filter { $0.ownerID == uid } ?? []
            if l.shareEvents {
                effects += backfillGroup(l)
                for ge in mine where my.events[ge.id] != nil {
                    if let e = my.events[ge.id] {
                        let updated = GroupEvent(event: e, ownerID: uid, includeLocation: l.shareLocations)
                        mutateCache { $0.zones[l.zone]?.events[ge.id] = updated }
                        effects.append(.save(.groupEvent(l.zone, ge.id)))
                    }
                }
            } else {
                for ge in mine {
                    mutateCache { $0.zones[l.zone]?.events[ge.id] = nil }
                    effects.append(.delete(.groupEvent(l.zone, ge.id)))
                }
            }
        }
        emit(effects)
    }

    /// Removes my membership locally. The service leaves the share (or deletes the zone if I own it).
    func removeGroupLocal(_ groupID: UUID) {
        guard let l = my.groupLinks[groupID] else { return }
        var effects: [Effect] = [.delete(.groupLink(groupID))]
        if !l.isOwner, let uid = my.userID {
            // Clean up what I wrote into their zone before leaving.
            let mine = cache.zones[l.zone]?.events.values.filter { $0.ownerID == uid }.map { $0.id } ?? []
            effects += mine.map { .delete(.groupEvent(l.zone, $0)) }
            effects.append(.delete(.member(l.zone, uid)))
        }
        mutateMy { $0.groupLinks[groupID] = nil }
        mutateCache { $0.zones[l.zone] = nil }
        emit(effects + [.refreshSubscriptions, .refreshDirectory])
    }

    func renameGroup(_ groupID: UUID, name: String, object: GroupObject? = nil, color: IdentityColor? = nil) -> Bool {
        guard let l = my.groupLinks[groupID], var info = cache.zones[l.zone]?.group, let clean = ContentFilter.cleanGroupName(name) else { return false }
        info.name = clean
        if let o = object { info.object = o }
        if let c = color { info.color = c }
        info.updatedAt = clock()
        let updated = info
        mutateCache { $0.zones[l.zone]?.group = updated }
        var link = l
        link.nameCache = clean
        mutateMy { $0.groupLinks[groupID] = link }
        emit([.save(.groupInfo(l.zone)), .save(.groupLink(groupID)), .refreshDirectory])
        return true
    }

    // MARK: - Ad-hoc spaces

    func registerSpace(_ link: SpaceLink) {
        mutateMy { $0.spaceLinks[link.zone] = link }
        mutateCache { c in if c.zones[link.zone] == nil { c.zones[link.zone] = ZoneCache(zone: link.zone) } }
        emit([.save(.spaceLink(link.zone))])
    }

    func removeSpace(_ zone: ZoneRef) {
        archiveSessions(in: zone)
        mutateMy { $0.spaceLinks[zone] = nil }
        mutateCache { $0.zones[zone] = nil }
        emit([.delete(.spaceLink(zone))])
    }

    /// Spaces past their expiry; the service deletes (owner) or leaves (participant) them.
    func expiredSpaces(now: Date? = nil) -> [SpaceLink] {
        let n = now ?? clock()
        return my.spaceLinks.values.filter { $0.expiresAt < n }
    }
}
