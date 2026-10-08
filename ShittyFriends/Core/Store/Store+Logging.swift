import Foundation

public extension Store {
    // MARK: - POOPING

    /// Single tap: +1 immediately and start a live timed session.
    /// If a session is already live, returns it instead of double-counting.
    @discardableResult
    func startTimed(pwmSessionID: UUID? = nil, partyID: UUID? = nil, attachLocation: Bool? = nil) -> PoopEvent {
        if let live = liveEvent {
            if pwmSessionID != nil || partyID != nil {
                // Joining a social session while already pooping: attach it to the running session.
                var e = live
                if let s = pwmSessionID { e.pwmSessionID = s }
                if let p = partyID { e.partyID = p }
                e.updatedAt = clock()
                put(e)
                emit([.save(.event(e.id))] + mirrorEffects(for: e))
                return e
            }
            return live
        }
        let now = clock()
        let event = PoopEvent(source: .timed, startedAt: now, pwmSessionID: pwmSessionID, partyID: partyID, sharedToGroups: true, createdAt: now, updatedAt: now)
        put(event)
        resetTapFeedback()
        undo = UndoToken(eventID: event.id, source: .timed, at: now)
        var effects: [Effect] = [.haptic(.logHeavy), .save(.event(event.id))]
        effects += mirrorEffects(for: event)
        effects.append(.ping(.poop(eventID: event.id, kind: .poopStart)))
        // Every poop is pinned (the app is a poop map); there is no per-user or per-poop opt-out.
        if attachLocation ?? true { effects.append(.requestLocation(eventID: event.id)) }
        if my.settings.longSessionReminder {
            effects.append(.scheduleLongSessionReminder(eventID: event.id, at: now.addingTimeInterval(30 * 60)))
        }
        emit(effects)
        onSessionChange?(event)
        evaluateAchievements()
        return event
    }

    /// Double tap: +1 immediately, no live session.
    @discardableResult
    func logInstant(attachLocation: Bool? = nil) -> PoopEvent {
        let now = clock()
        let event = PoopEvent(source: .instant, startedAt: now, sharedToGroups: true, createdAt: now, updatedAt: now)
        put(event)
        undo = UndoToken(eventID: event.id, source: .instant, at: now)
        var effects: [Effect] = [.haptic(.logHeavy), .save(.event(event.id))]
        effects += mirrorEffects(for: event)
        effects.append(.ping(.poop(eventID: event.id, kind: .poopInstant)))
        if attachLocation ?? true { effects.append(.requestLocation(eventID: event.id)) }
        emit(effects)
        evaluateAchievements()
        return event
    }

    /// DONE. Ends the live timer. The poop already counted.
    func finish(_ eventID: UUID? = nil, at end: Date? = nil) {
        guard let id = eventID ?? liveEvent?.id, var e = my.events[id], e.isLive else { return }
        let now = clock()
        e.endedAt = max(e.startedAt, end ?? now)
        e.updatedAt = now
        put(e)
        var effects: [Effect] = [.save(.event(id)), .cancelLongSessionReminder(eventID: id), .cancelPings(eventID: id), .haptic(.success)]
        effects += mirrorEffects(for: e)
        effects += participantDoneEffects(for: e)
        emit(effects)
        onSessionChange?(nil)
        if undo?.eventID == id { undo = nil }
        evaluateAchievements()
    }

    /// Undo the most recent log (only inside the undo window).
    func performUndo() {
        guard let u = undo, clock().timeIntervalSince(u.at) <= Store.undoWindow + 1 else { undo = nil; return }
        undo = nil
        // A mis-tap is erased completely, including the few points it may have earned.
        delete(u.eventID, keepPoints: false)
    }

    func clearUndo() { undo = nil }

    /// Add a missed poop later. Never produces live presence or "is pooping" alerts.
    @discardableResult
    func addManual(at start: Date, duration: TimeInterval?, location: PoopLocation?) -> PoopEvent {
        let now = clock()
        let end = duration.map { start.addingTimeInterval(max(0, $0)) }
        let event = PoopEvent(source: .manual, startedAt: min(start, now), endedAt: end, location: location, sharedToGroups: true, createdAt: now, updatedAt: now)
        put(event)
        emit([.save(.event(event.id)), .haptic(.success)] + mirrorEffects(for: event))
        evaluateAchievements()
        return event
    }

    /// Edit times/location afterwards (also how forgotten timers get fixed).
    func edit(_ id: UUID, start: Date? = nil, end: Date?? = nil, location: PoopLocation?? = nil, sharedToGroups: Bool? = nil) {
        guard var e = my.events[id] else { return }
        let wasLive = e.isLive
        if let s = start { e.startedAt = s }
        if let newEnd = end {
            if newEnd == nil && e.source == .timed && !wasLive {
                // A finished timer never becomes live again (that would fake "currently pooping").
                if let currentEnd = e.endedAt, currentEnd < e.startedAt { e.endedAt = e.startedAt }
            } else {
                e.endedAt = newEnd.map { max(e.startedAt, $0) }
            }
            if e.source == .instant { e.endedAt = nil }
        } else if let currentEnd = e.endedAt, currentEnd < e.startedAt {
            e.endedAt = e.startedAt
        }
        if let loc = location { e.location = loc }
        if let shared = sharedToGroups { e.sharedToGroups = shared }
        e.manuallyAdjusted = true
        e.updatedAt = clock()
        put(e)
        var effects: [Effect] = [.save(.event(id))]
        effects += mirrorEffects(for: e)
        if wasLive && !e.isLive {
            effects += [.cancelLongSessionReminder(eventID: id), .cancelPings(eventID: id)]
            effects += participantDoneEffects(for: e)
        }
        emit(effects)
        if wasLive { onSessionChange?(e.isLive ? e : nil) }
        evaluateAchievements()
    }

    /// Deletes one of my poops. Points it earned are banked on the profile (by default), so cleaning up
    /// history never lowers the balance or takes back cosmetics that were already bought with them.
    func delete(_ id: UUID, keepPoints: Bool = true) {
        guard let e = my.events[id] else { return }
        var bankedProfile: UserProfile?
        if keepPoints, e.halfPoints > 0, var p = my.profile {
            p.bankedHalfPoints += e.halfPoints
            p.updatedAt = clock()
            bankedProfile = p
        }
        mutateMy {
            $0.events[id] = nil
            if let p = bankedProfile { $0.profile = p }
        }
        var effects: [Effect] = [.delete(.event(id)), .cancelPings(eventID: id), .cancelLongSessionReminder(eventID: id)]
        if bankedProfile != nil { effects.append(.save(.profile)) }
        for link in my.groupLinks.values where cache.zones[link.zone]?.events[id] != nil {
            mutateCache { $0.zones[link.zone]?.events[id] = nil }
            effects.append(.delete(.groupEvent(link.zone, id)))
        }
        if e.isLive { effects += participantDoneEffects(for: e, declined: true) }
        emit(effects)
        if e.isLive { onSessionChange?(nil) }
    }

    /// Location arrived from CoreLocation (does not count as a manual adjustment).
    func attachLocation(_ location: PoopLocation, to id: UUID) {
        guard var e = my.events[id] else { return }
        e.location = location
        e.updatedAt = clock()
        put(e)
        emit([.save(.event(id))] + mirrorEffects(for: e))
        evaluateAchievements()
    }

    // MARK: - Tapping

    /// One tap on the big poop during a live session.
    @discardableResult
    func tapPoop() -> TapOutcome? {
        guard var e = liveEvent else { return nil }
        let now = clock()
        var state = tapState
        if tapEventID != e.id {
            // First tap of this session on this launch (or after switching sessions): never carry
            // combo / "cap reached" state over from another session.
            state = TapState()
            tapEventID = e.id
            lastTap = nil
        }
        let outcome = PointsEngine.tap(at: now, sessionTapsBefore: e.taps, sessionHalfPointsBefore: e.halfPoints, state: &state, rules: rules, roll: randomRoll())
        tapState = state
        e.taps += 1
        e.halfPoints += outcome.gainedHalfPoints
        // Persist locally; the record syncs on DONE to avoid a CloudKit write per tap.
        my.events[e.id] = e
        tapPulse &+= 1
        lastTap = outcome
        dirty(.my)
        emit([.haptic(outcome.isCritical ? .tapCritical : .tapLight)])
        return outcome
    }

    // MARK: - Helpers

    /// Clears per-session tap feedback so a new session never shows the previous one's combo or cap.
    internal func resetTapFeedback() {
        tapState = TapState()
        tapEventID = nil
        lastTap = nil
    }

    internal func put(_ e: PoopEvent) {
        mutateMy { $0.events[e.id] = e }
    }

    /// Mirrors an event into every group that has event sharing on (or removes it if unshared).
    internal func mirrorEffects(for e: PoopEvent) -> [Effect] {
        guard let uid = my.userID else { return [] }
        var effects: [Effect] = []
        for link in my.groupLinks.values {
            let zone = link.zone
            if link.shareEvents && e.sharedToGroups {
                let ge = GroupEvent(event: e, ownerID: uid, includeLocation: link.shareLocations)
                mutateCache { c in
                    if c.zones[zone] == nil { c.zones[zone] = ZoneCache(zone: zone) }
                    c.zones[zone]?.events[e.id] = ge
                }
                effects.append(.save(.groupEvent(zone, e.id)))
            } else if cache.zones[zone]?.events[e.id] != nil {
                mutateCache { $0.zones[zone]?.events[e.id] = nil }
                effects.append(.delete(.groupEvent(zone, e.id)))
            }
        }
        return effects
    }

    /// When my session ends, mark me done in its Poop With Me session.
    internal func participantDoneEffects(for e: PoopEvent, declined: Bool = false) -> [Effect] {
        guard let sid = e.pwmSessionID, let uid = my.userID else { return [] }
        var effects: [Effect] = []
        for (zone, z) in cache.zones {
            guard var p = z.participants[sid]?[uid] else { continue }
            p.status = declined ? .declined : .done
            p.endedAt = declined ? nil : (e.endedAt ?? clock())
            p.updatedAt = clock()
            let updated = p
            mutateCache { $0.zones[zone]?.participants[sid]?[uid] = updated }
            effects.append(.save(.participant(zone, sid, uid)))
            effects += maybeEndSession(zone: zone, sessionID: sid)
        }
        return effects
    }
}
