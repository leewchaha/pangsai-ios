import Foundation

public extension Store {
    /// Me + my full friends (their whole history is visible to me).
    func friendHighlightParticipants() -> [HighlightParticipant] {
        var out: [HighlightParticipant] = []
        out.append(HighlightParticipant(id: userID ?? UserID.localMe, handle: profile.handle, color: profile.color, events: my.events.values.map(HighlightEvent.init)))
        for s in friendSummaries() {
            let events = friendEvents(s.person.id).map(HighlightEvent.init)
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
        for e in z.events.values { byOwner[e.ownerID, default: []].append(HighlightEvent(e)) }
        return members.map { m in
            let label = labels[m.id].map { String($0.dropFirst()) } ?? m.person.handle
            return HighlightParticipant(id: m.id, handle: label, color: m.person.color, events: byOwner[m.id] ?? [])
        }
    }

    func highlightCards(period: HighlightPeriod, reference: Date? = nil) -> [HighlightCard] {
        HighlightsEngine.cards(for: friendHighlightParticipants(), period: period, reference: reference ?? clock(), calendar: calendar, isGroup: false)
    }

    func groupHighlightCards(_ zone: ZoneRef, period: HighlightPeriod, reference: Date? = nil) -> [HighlightCard] {
        HighlightsEngine.cards(for: groupHighlightParticipants(zone), period: period, reference: reference ?? clock(), calendar: calendar, isGroup: true)
    }

    /// Map points I'm allowed to see: mine, friends' (full history), and group-shared locations.
    func mapPoints(includeMine: Bool = true, friendIDs: Set<UserID>? = nil, groupZones: Set<ZoneRef> = []) -> [MapPoint] {
        var out: [MapPoint] = []
        let me = userID ?? UserID.localMe
        var seen = Set<UUID>()
        if includeMine {
            for e in my.events.values {
                guard let l = e.location else { continue }
                seen.insert(e.id)
                out.append(MapPoint(id: e.id.uuidString, ownerID: me, latitude: l.latitude, longitude: l.longitude, label: l.label, date: e.startedAt))
            }
        }
        for s in friendSummaries() where friendIDs?.contains(s.person.id) ?? true {
            for e in friendEvents(s.person.id) {
                guard let l = e.location, !seen.contains(e.id) else { continue }
                seen.insert(e.id)
                out.append(MapPoint(id: e.id.uuidString, ownerID: s.person.id, latitude: l.latitude, longitude: l.longitude, label: l.label, date: e.startedAt))
            }
        }
        for zone in groupZones {
            for e in cache.zones[zone]?.events.values.map({ $0 }) ?? [] {
                guard let l = e.location, !seen.contains(e.id) else { continue }
                seen.insert(e.id)
                out.append(MapPoint(id: e.id.uuidString, ownerID: e.ownerID, latitude: l.latitude, longitude: l.longitude, label: l.label, date: e.startedAt))
            }
        }
        return out
    }
}
