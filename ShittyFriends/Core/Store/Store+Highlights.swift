import Foundation

public extension Store {
    /// Me + my full friends (their whole history is visible to me). Ranks people, so only
    /// live-logged poops take part (`countsForRanking`).
    func friendHighlightParticipants() -> [HighlightParticipant] {
        var out: [HighlightParticipant] = []
        out.append(HighlightParticipant(id: userID ?? UserID.localMe, handle: profile.handle, color: profile.color, events: my.events.values.filter { $0.countsForRanking }.map(HighlightEvent.init)))
        for s in friendSummaries() {
            let events = friendEvents(s.person.id).filter { $0.countsForRanking }.map(HighlightEvent.init)
            out.append(HighlightParticipant(id: s.person.id, handle: s.person.handle, color: s.person.color, events: events))
        }
        return out
    }

    /// Group members, using only what was shared into the group. Duplicate handles get their (1)/(2) labels.
    func groupHighlightParticipants(_ zone: ZoneRef) -> [HighlightParticipant] {
        guard let z = cache.zones[zone] else { return [] }
        let members = z.members.values.sorted { $0.joinedAt < $1.joinedAt }
        let labels = HandleRules.groupLabels(members.map { ($0.id, $0.person.handle, $0.joinedAt) })
        var byOwner: [UserID: [HighlightEvent]] = [:]
        for e in z.events.values where e.countsForRanking { byOwner[e.ownerID, default: []].append(HighlightEvent(e)) }
        return members.map { m in
            let label = labels[m.id].map { String($0.dropFirst()) } ?? m.person.handle
            return HighlightParticipant(id: m.id, handle: label, color: m.person.color, events: byOwner[m.id] ?? [])
        }
    }

    func highlightCards(period: HighlightPeriod, reference: Date? = nil) -> [HighlightCard] {
        HighlightsEngine.cards(for: friendHighlightParticipants(), period: period, reference: reference ?? clock(), calendar: calendar, isGroup: false)
    }

    /// Personal highlights: only my own poops (the YOU tab and the daily/weekly/monthly reports).
    /// Personal stats include everything in history, manual and imported poops too.
    func myHighlightCards(period: HighlightPeriod, reference: Date? = nil) -> [HighlightCard] {
        let me = HighlightParticipant(id: userID ?? UserID.localMe, handle: profile.handle, color: profile.color, events: my.events.values.map(HighlightEvent.init))
        return HighlightsEngine.cards(for: [me], period: period, reference: reference ?? clock(), calendar: calendar, isGroup: false)
    }

    func groupHighlightCards(_ zone: ZoneRef, period: HighlightPeriod, reference: Date? = nil) -> [HighlightCard] {
        HighlightsEngine.cards(for: groupHighlightParticipants(zone), period: period, reference: reference ?? clock(), calendar: calendar, isGroup: true)
    }

    /// Map-first Home only needs the newest located poop for each visible person.
    /// This both matches the Zenly-style product model and avoids rebuilding thousands of history pins.
    func latestMapPoints(includeMine: Bool = true, friendIDs: Set<UserID>? = nil, groupZones: Set<ZoneRef> = []) -> [MapPoint] {
        let me = userID ?? UserID.localMe
        var latest: [UserID: MapPoint] = [:]

        func consider(id: UUID, ownerID: UserID, event: PoopEvent) {
            guard let location = event.location else { return }
            let point = MapPoint(
                id: id.uuidString,
                ownerID: ownerID,
                latitude: location.latitude,
                longitude: location.longitude,
                label: location.label,
                date: event.startedAt
            )
            if let old = latest[ownerID], old.date >= point.date { return }
            latest[ownerID] = point
        }

        if includeMine {
            for event in my.events.values { consider(id: event.id, ownerID: me, event: event) }
        }

        for link in activeFriendLinks {
            guard let uid = link.userID, friendIDs?.contains(uid) ?? true, let friend = cache.friends[uid] else { continue }
            for event in friend.events.values {
                consider(id: event.id, ownerID: uid, event: event)
            }
        }

        for zone in groupZones {
            guard let zoneCache = cache.zones[zone] else { continue }
            for event in zoneCache.events.values {
                guard let location = event.location else { continue }
                let point = MapPoint(
                    id: event.id.uuidString,
                    ownerID: event.ownerID,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    label: location.label,
                    date: event.startedAt
                )
                if let old = latest[event.ownerID], old.date >= point.date { continue }
                latest[event.ownerID] = point
            }
        }

        return latest.values.sorted { $0.date > $1.date }
    }

    /// Every located poop I'm allowed to see (Home map history): mine, friends' (full history), and
    /// group-shared locations. Each event appears once even if it reached me through several routes.
    func mapPoints(includeMine: Bool = true, friendIDs: Set<UserID>? = nil, groupZones: Set<ZoneRef> = []) -> [MapPoint] {
        var out: [MapPoint] = []
        let me = userID ?? UserID.localMe
        var seen = Set<UUID>()

        func add<E: PoopLike>(_ e: E, id: UUID, owner: UserID) {
            guard let l = e.location, !seen.contains(id) else { return }
            seen.insert(id)
            let live = e.source == .timed && e.endedAt == nil
            var duration: TimeInterval?
            if e.source != .instant, let end = e.endedAt { duration = max(0, end.timeIntervalSince(e.startedAt)) }
            out.append(MapPoint(id: id.uuidString, ownerID: owner, latitude: l.latitude, longitude: l.longitude, label: l.label, date: e.startedAt, duration: duration, isLive: live))
        }

        if includeMine {
            for e in my.events.values { add(e, id: e.id, owner: me) }
        }
        for s in friendSummaries() where friendIDs?.contains(s.person.id) ?? true {
            for e in friendEvents(s.person.id) { add(e, id: e.id, owner: s.person.id) }
        }
        for zone in groupZones {
            for e in cache.zones[zone]?.events.values.map({ $0 }) ?? [] { add(e, id: e.id, owner: e.ownerID) }
        }
        return out.sorted { $0.date > $1.date }
    }
}
