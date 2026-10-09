import Foundation

/// Trophies a whole group earns together (handoff §15.1 / §17). They reward doing things *together*
/// — never a higher poop count — and are computed from what the group can already see, so there is
/// nothing extra to store or sync.
public enum GroupAchievementID: String, CaseIterable, Sendable, Identifiable, Hashable {
    case fullHouse, synchronized, tagTeam, partyOn, nightShiftCrew, internationalIncident

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullHouse: return "Full House"
        case .synchronized: return "Synchronized"
        case .tagTeam: return "Tag Team"
        case .partyOn: return "Party On"
        case .nightShiftCrew: return "Night Shift Crew"
        case .internationalIncident: return "International Incident"
        }
    }

    public var detail: String {
        switch self {
        case .fullHouse: return "Every member logged on the same day (3+ members)."
        case .synchronized: return "Three of you logged within 10 minutes."
        case .tagTeam: return "A Poop With Me with three or more people actually pooping."
        case .partyOn: return "A Poop Party that three or more of you joined."
        case .nightShiftCrew: return "Three of you logged between midnight and 4:00 on the same night."
        case .internationalIncident: return "Two of you logged from two different countries (with locations shared here)."
        }
    }

    public var object: TrophyObject {
        switch self {
        case .fullHouse: return .crown
        case .synchronized: return .meltingClock
        case .tagTeam: return .twinToilets
        case .partyOn: return .partyHat
        case .nightShiftCrew: return .moon
        case .internationalIncident: return .globe
        }
    }
}

public struct GroupAchievementStatus: Hashable, Sendable, Identifiable {
    public var id: GroupAchievementID
    /// When it was first earned, or nil if not yet.
    public var earnedAt: Date?

    public var earned: Bool { earnedAt != nil }
}

public enum GroupAchievementEngine {
    public static let minimumCrew = 3

    public static func evaluate(
        events allEvents: [GroupEvent],
        members: [GroupMember],
        sessionParticipants: [[PWMParticipant]],
        partyRSVPs: [[PartyRSVP]],
        calendar: Calendar
    ) -> [GroupAchievementStatus] {
        // Only live-logged poops; manual, edited and imported copies never earn a trophy.
        let events = allEvents.filter { $0.countsForRanking }
        return GroupAchievementID.allCases.map { id in
            let at: Date?
            switch id {
            case .fullHouse: at = fullHouse(events, members: members, calendar: calendar)
            case .synchronized: at = synchronized(events)
            case .tagTeam: at = tagTeam(sessionParticipants)
            case .partyOn: at = partyOn(partyRSVPs)
            case .nightShiftCrew: at = nightShiftCrew(events, calendar: calendar)
            case .internationalIncident: at = international(events)
            }
            return GroupAchievementStatus(id: id, earnedAt: at)
        }
    }

    /// First day on which everyone who was a member by the end of that day logged (3+ members).
    static func fullHouse(_ events: [GroupEvent], members: [GroupMember], calendar: Calendar) -> Date? {
        var byDay: [DayKey: [UserID: Date]] = [:]
        for e in events {
            let day = DayKey(e.startedAt, calendar: calendar)
            let current = byDay[day]?[e.ownerID]
            if current == nil || e.startedAt < current! { byDay[day, default: [:]][e.ownerID] = e.startedAt }
        }
        for day in byDay.keys.sorted() {
            guard let loggers = byDay[day] else { continue }
            let end = day.adding(days: 1, calendar: calendar).startDate(calendar: calendar)
            let required = members.filter { $0.joinedAt < end }.map(\.id)
            guard required.count >= minimumCrew, required.allSatisfy({ loggers[$0] != nil }) else { continue }
            return required.compactMap { loggers[$0] }.max()
        }
        return nil
    }

    /// Three different people inside any 10-minute window.
    static func synchronized(_ events: [GroupEvent], window: TimeInterval = 10 * 60) -> Date? {
        let sorted = events.sorted { $0.startedAt < $1.startedAt }
        var start = 0
        for end in sorted.indices {
            while sorted[end].startedAt.timeIntervalSince(sorted[start].startedAt) > window { start += 1 }
            let people = Set(sorted[start...end].map(\.ownerID))
            if people.count >= minimumCrew { return sorted[end].startedAt }
        }
        return nil
    }

    static func tagTeam(_ sessions: [[PWMParticipant]]) -> Date? {
        sessions.compactMap { ps -> Date? in
            let poopers = ps.filter { $0.status == .joined || $0.status == .done }
            guard poopers.count >= minimumCrew else { return nil }
            return poopers.compactMap(\.startedAt).sorted().dropFirst(minimumCrew - 1).first
        }.min()
    }

    static func partyOn(_ parties: [[PartyRSVP]]) -> Date? {
        parties.compactMap { rs -> Date? in
            let joined = rs.compactMap(\.joinedAt).sorted()
            guard joined.count >= minimumCrew else { return nil }
            return joined[minimumCrew - 1]
        }.min()
    }

    static func nightShiftCrew(_ events: [GroupEvent], calendar: Calendar) -> Date? {
        var nights: [DayKey: [UserID: Date]] = [:]
        for e in events {
            let minutes = CalendarMath.minutesFromMidnight(e.startedAt, calendar: calendar)
            guard minutes < 4 * 60 else { continue }
            let day = DayKey(e.startedAt, calendar: calendar)
            if nights[day]?[e.ownerID] == nil { nights[day, default: [:]][e.ownerID] = e.startedAt }
        }
        for day in nights.keys.sorted() {
            guard let people = nights[day], people.count >= minimumCrew else { continue }
            return people.values.sorted()[minimumCrew - 1]
        }
        return nil
    }

    /// Two *different members* in two different countries. One person's holiday abroad doesn't make
    /// an incident; the group earns this together, like every other trophy here.
    static func international(_ events: [GroupEvent]) -> Date? {
        var countryByPerson: [UserID: Set<String>] = [:]
        for e in events.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let code = (e.location?.countryCode ?? e.location?.country)?.uppercased(), !code.isEmpty else { continue }
            countryByPerson[e.ownerID, default: []].insert(code)
            // Earned the moment some other member has logged from a country this one hasn't.
            for (other, codes) in countryByPerson where other != e.ownerID {
                if codes.contains(where: { $0 != code }) { return e.startedAt }
            }
        }
        return nil
    }
}

public extension Store {
    /// Group trophies, computed from the group's shared poops, sessions and parties.
    func groupAchievements(_ zone: ZoneRef) -> [GroupAchievementStatus] {
        guard let z = cache.zones[zone] else {
            return GroupAchievementID.allCases.map { GroupAchievementStatus(id: $0, earnedAt: nil) }
        }
        return GroupAchievementEngine.evaluate(
            events: Array(z.events.values),
            members: Array(z.members.values),
            sessionParticipants: z.participants.values.map { Array($0.values) },
            partyRSVPs: z.rsvps.values.map { Array($0.values) },
            calendar: calendar
        )
    }

    /// Me and my friends ranked for a period (handoff §18 "individual friend comparisons").
    /// Highest first; ties by handle. Live-logged poops only (`countsForRanking`).
    func friendLeaderboard(period: HighlightPeriod = .week, now: Date? = nil) -> [(person: PersonRef, count: Int)] {
        let interval = period.interval(containing: now ?? clock(), calendar: calendar)
        var rows: [(person: PersonRef, count: Int)] = [(meRef, my.events.values.filter { $0.countsForRanking && interval.contains($0.startedAt) }.count)]
        for link in activeFriendLinks {
            guard let uid = link.userID else { continue }
            let fc = cache.friends[uid]
            let person = fc?.profile.map { PersonRef(id: uid, profile: $0) } ?? link.person ?? PersonRef(id: uid, handle: "friend", avatar: AvatarSpec(), color: IdentityColor.stable(for: uid))
            let count = fc?.events.values.filter { $0.countsForRanking && interval.contains($0.startedAt) }.count ?? 0
            rows.append((person, count))
        }
        return rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.person.handle.lowercased() < $1.person.handle.lowercased() }
    }
}
