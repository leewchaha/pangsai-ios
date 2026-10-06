import Foundation

public extension Store {
    // MARK: - Poop With Me

    /// Starts a Poop With Me session from my live session. `zone` is a group zone or an ad-hoc
    /// session zone already registered with `registerSpace`.
    @discardableResult
    func createPWMSession(zone: ZoneRef, groupID: UUID?, invitees: [PersonRef]) -> UUID? {
        guard let uid = my.userID, var live = liveEvent else { return nil }
        let now = clock()
        let session = PWMSession(creatorID: uid, groupID: groupID, createdAt: now, updatedAt: now)
        let mine = PWMParticipant(sessionID: session.id, person: meRef, status: .joined, startedAt: live.startedAt, eventID: live.id, updatedAt: now)
        let invited = invitees.filter { $0.id != uid }.map { PWMParticipant(sessionID: session.id, person: $0, status: .invited, updatedAt: now) }

        live.pwmSessionID = session.id
        live.updatedAt = now
        put(live)

        mutateCache { c in
            if c.zones[zone] == nil { c.zones[zone] = ZoneCache(zone: zone) }
            c.zones[zone]?.sessions[session.id] = session
            var ps: [UserID: PWMParticipant] = [uid: mine]
            for p in invited { ps[p.id] = p }
            c.zones[zone]?.participants[session.id] = ps
        }
        var effects: [Effect] = [.save(.event(live.id)), .save(.pwmSession(zone, session.id)), .save(.participant(zone, session.id, uid))]
        effects += invited.map { .save(.participant(zone, session.id, $0.id)) }
        effects += mirrorEffects(for: live)
        effects.append(.ping(.pwmInvite(zone: zone, sessionID: session.id, invitees: invited.map { $0.id })))
        emit(effects)
        return session.id
    }

    /// Invite more people to a session that already exists.
    func inviteMore(zone: ZoneRef, sessionID: UUID, invitees: [PersonRef]) {
        guard let uid = my.userID else { return }
        let now = clock()
        let existing = cache.zones[zone]?.participants[sessionID] ?? [:]
        let fresh = invitees.filter { $0.id != uid && existing[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        mutateCache { c in
            for p in fresh {
                c.zones[zone]?.participants[sessionID, default: [:]][p.id] = PWMParticipant(sessionID: sessionID, person: p, status: .invited, updatedAt: now)
            }
        }
        emit(fresh.map { .save(.participant(zone, sessionID, $0.id)) } + [.ping(.pwmInvite(zone: zone, sessionID: sessionID, invitees: fresh.map { $0.id }))])
    }

    /// JOIN = "I am actually pooping now": +1 immediately, my own timer starts.
    @discardableResult
    func joinPWM(zone: ZoneRef, sessionID: UUID) -> PoopEvent? {
        guard let uid = my.userID else { return nil }
        let event = startTimed(pwmSessionID: sessionID)
        let now = clock()
        var p = cache.zones[zone]?.participants[sessionID]?[uid] ?? PWMParticipant(sessionID: sessionID, person: meRef, status: .invited)
        p.person = meRef
        p.status = .joined
        p.startedAt = event.startedAt
        p.endedAt = nil
        p.eventID = event.id
        p.updatedAt = now
        let updated = p
        mutateCache { c in
            if c.zones[zone] == nil { c.zones[zone] = ZoneCache(zone: zone) }
            c.zones[zone]?.participants[sessionID, default: [:]][uid] = updated
        }
        emit([.save(.participant(zone, sessionID, uid)), .ping(.pwmJoin(zone: zone, sessionID: sessionID))])
        confirmSocialSession(zone: zone, sessionID: sessionID)
        return event
    }

    func declinePWM(zone: ZoneRef, sessionID: UUID) {
        guard let uid = my.userID, var p = cache.zones[zone]?.participants[sessionID]?[uid] else { return }
        p.status = .declined
        p.updatedAt = clock()
        let updated = p
        mutateCache { $0.zones[zone]?.participants[sessionID]?[uid] = updated }
        emit([.save(.participant(zone, sessionID, uid))] + maybeEndSession(zone: zone, sessionID: sessionID))
    }

    @discardableResult
    func sendReaction(zone: ZoneRef, sessionID: UUID, kind: ReactionKind) -> Reaction? {
        guard let uid = my.userID else { return nil }
        let r = Reaction(sessionID: sessionID, senderID: uid, kind: kind, cosmetic: profile.equippedCosmetic, at: clock())
        mutateCache { c in c.zones[zone]?.reactions[r.id] = r }
        emit([.save(.reaction(zone, r.id)), .haptic(.reaction)])
        return r
    }

    func reactions(zone: ZoneRef, sessionID: UUID, since: Date) -> [Reaction] {
        (cache.zones[zone]?.reactions.values.filter { $0.sessionID == sessionID && $0.at > since } ?? []).sorted { $0.at < $1.at }
    }

    /// Ends the session record once nobody is still pooping (and somebody actually took part).
    internal func maybeEndSession(zone: ZoneRef, sessionID: UUID) -> [Effect] {
        guard var s = cache.zones[zone]?.sessions[sessionID], s.state == .open else { return [] }
        let ps = Array((cache.zones[zone]?.participants[sessionID] ?? [:]).values)
        let anyoneLive = ps.contains { $0.status == .joined }
        let anyoneDone = ps.contains { $0.status == .done }
        guard !anyoneLive && anyoneDone else { return [] }
        s.state = .ended
        s.updatedAt = clock()
        let ended = s
        mutateCache { $0.zones[zone]?.sessions[sessionID] = ended }
        archiveSession(zone: zone, sessionID: sessionID)
        // Clean up my reactions; they're ephemeral.
        var effects: [Effect] = [.save(.pwmSession(zone, sessionID))]
        if let uid = my.userID {
            let mine = cache.zones[zone]?.reactions.values.filter { $0.sessionID == sessionID && $0.senderID == uid }.map { $0.id } ?? []
            mutateCache { c in for id in mine { c.zones[zone]?.reactions[id] = nil } }
            effects += mine.map { .delete(.reaction(zone, $0)) }
        }
        return effects
    }

    internal func confirmSocialSession(zone: ZoneRef, sessionID: UUID) {
        guard let uid = my.userID else { return }
        let ps = Array((cache.zones[zone]?.participants[sessionID] ?? [:]).values)
        let poopers = ps.filter { $0.status == .joined || $0.status == .done }
        guard poopers.count >= 2, poopers.contains(where: { $0.id == uid }), !my.confirmedSocialSessions.contains(sessionID) else { return }
        mutateMy { $0.confirmedSocialSessions.insert(sessionID) }
        evaluateAchievements()
    }

    internal func archiveSession(zone: ZoneRef, sessionID: UUID) {
        guard let s = cache.zones[zone]?.sessions[sessionID] else { return }
        let ps = (cache.zones[zone]?.participants[sessionID] ?? [:]).values.filter { $0.status == .joined || $0.status == .done }.map { $0.person }
        guard ps.contains(where: { $0.id == my.userID }) || s.creatorID == my.userID else { return }
        let entry = PWMArchiveEntry(sessionID: s.id, creatorID: s.creatorID, groupID: s.groupID, createdAt: s.createdAt, participants: ps.sorted { $0.handle < $1.handle })
        mutateMy { $0.pwmArchive[s.id] = entry }
    }

    internal func archiveSessions(in zone: ZoneRef) {
        for id in cache.zones[zone]?.sessions.keys.map({ $0 }) ?? [] { archiveSession(zone: zone, sessionID: id) }
    }

    // MARK: - Poop Parties

    @discardableResult
    func createParty(zone: ZoneRef, groupID: UUID?, title: String, at date: Date, invitees: [PersonRef]) -> UUID? {
        guard let uid = my.userID else { return nil }
        let now = clock()
        let cleanTitle = ContentFilter.cleanGroupName(title) ?? "Poop Party"
        let party = Party(creatorID: uid, groupID: groupID, title: cleanTitle, scheduledAt: date, createdAt: now, updatedAt: now)
        var rsvps: [UserID: PartyRSVP] = [uid: PartyRSVP(partyID: party.id, person: meRef, response: .yes, updatedAt: now)]
        for p in invitees where p.id != uid {
            rsvps[p.id] = PartyRSVP(partyID: party.id, person: p, response: .maybe, updatedAt: now)
        }
        mutateCache { c in
            if c.zones[zone] == nil { c.zones[zone] = ZoneCache(zone: zone) }
            c.zones[zone]?.parties[party.id] = party
            c.zones[zone]?.rsvps[party.id] = rsvps
        }
        var effects: [Effect] = [.save(.party(zone, party.id))]
        effects += rsvps.keys.sorted().map { .save(.rsvp(zone, party.id, $0)) }
        effects += [.scheduleParty(zone: zone, partyID: party.id), .ping(.partyInvite(zone: zone, partyID: party.id, invitees: invitees.map { $0.id }.filter { $0 != uid }))]
        emit(effects)
        return party.id
    }

    func rsvp(zone: ZoneRef, partyID: UUID, response: RSVPResponse) {
        guard let uid = my.userID else { return }
        let now = clock()
        var r = cache.zones[zone]?.rsvps[partyID]?[uid] ?? PartyRSVP(partyID: partyID, person: meRef, response: response)
        r.person = meRef
        r.response = response
        r.updatedAt = now
        let updated = r
        mutateCache { $0.zones[zone]?.rsvps[partyID, default: [:]][uid] = updated }
        emit([.save(.rsvp(zone, partyID, uid)), response == .no ? .cancelParty(partyID: partyID) : .scheduleParty(zone: zone, partyID: partyID)])
    }

    /// Joining a party behaves like Poop With Me: +1 now, timer starts.
    @discardableResult
    func joinParty(zone: ZoneRef, partyID: UUID) -> PoopEvent? {
        guard let uid = my.userID else { return nil }
        let event = startTimed(partyID: partyID)
        let now = clock()
        var r = cache.zones[zone]?.rsvps[partyID]?[uid] ?? PartyRSVP(partyID: partyID, person: meRef, response: .yes)
        r.person = meRef
        if r.response == .no { r.response = .yes }
        r.joinedAt = now
        r.eventID = event.id
        r.updatedAt = now
        let updated = r
        mutateCache { $0.zones[zone]?.rsvps[partyID, default: [:]][uid] = updated }
        emit([.save(.rsvp(zone, partyID, uid))])
        evaluateAchievements()
        return event
    }

    func cancelParty(zone: ZoneRef, partyID: UUID) {
        guard var p = cache.zones[zone]?.parties[partyID], p.creatorID == my.userID else { return }
        p.status = .cancelled
        p.updatedAt = clock()
        let updated = p
        mutateCache { $0.zones[zone]?.parties[partyID] = updated }
        emit([.save(.party(zone, partyID)), .cancelParty(partyID: partyID)])
    }
}
