import Foundation

public struct AchievementContext {
    public var events: [PoopEvent]
    public var friendCount: Int
    /// Poop With Me sessions that had at least two people actually pooping (me included).
    public var completedSocialSessions: Int
    /// Parties I RSVP'd yes to whose time has passed, and whether I joined them.
    public var pastYesParties: [(partyID: UUID, scheduledAt: Date, joined: Bool)]
    public var ownedCosmetics: Int
    public var now: Date
    public var calendar: Calendar

    public init(events: [PoopEvent], friendCount: Int, completedSocialSessions: Int, pastYesParties: [(partyID: UUID, scheduledAt: Date, joined: Bool)], ownedCosmetics: Int, now: Date, calendar: Calendar) {
        self.events = events
        self.friendCount = friendCount
        self.completedSocialSessions = completedSocialSessions
        self.pastYesParties = pastYesParties
        self.ownedCosmetics = ownedCosmetics
        self.now = now
        self.calendar = calendar
    }
}

public struct AchievementProgress: Hashable, Sendable {
    public var current: Int
    public var target: Int
    public var fraction: Double { target == 0 ? 1 : min(1, Double(current) / Double(target)) }
}

public enum AchievementEngine {
    /// Achievements newly earned given what is already unlocked.
    public static func newlyUnlocked(_ ctx: AchievementContext, already: Set<AchievementID>) -> [AchievementUnlock] {
        var out: [AchievementUnlock] = []
        for id in AchievementID.allCases where !already.contains(id) {
            if let meta = check(id, ctx) {
                out.append(AchievementUnlock(id: id, unlockedAt: ctx.now, metadata: meta))
            }
        }
        return out
    }

    /// Returns metadata if earned, nil otherwise.
    public static func check(_ id: AchievementID, _ ctx: AchievementContext) -> [String: String]? {
        let cal = ctx.calendar
        let events = ctx.events
        switch id {
        case .firstDrop:
            return events.isEmpty ? nil : [:]
        case .sevenDay:
            let days = Set(events.map { DayKey($0.startedAt, calendar: cal) })
            return CalendarMath.streaks(days: days, today: DayKey(ctx.now, calendar: cal), calendar: cal).longest >= 7 ? [:] : nil
        case .monthlyRegular:
            var perMonth: [MonthKey: Set<DayKey>] = [:]
            for e in events { perMonth[MonthKey(e.startedAt, calendar: cal), default: []].insert(DayKey(e.startedAt, calendar: cal)) }
            if let hit = perMonth.first(where: { $0.value.count >= 25 }) {
                return ["month": String(format: "%04d-%02d", hit.key.year, hit.key.month)]
            }
            return nil
        case .clockwork:
            return clockwork(events, calendar: cal) ? [:] : nil
        case .firstFriend:
            return ctx.friendCount >= 1 ? [:] : nil
        case .poopPals:
            return ctx.completedSocialSessions >= 10 ? [:] : nil
        case .partyAnimal:
            return Set(events.compactMap { $0.partyID }).count >= 3 ? [:] : nil
        case .perfectAttendance:
            let windowStart = ctx.now.addingTimeInterval(-30 * 24 * 3600)
            let recent = ctx.pastYesParties.filter { $0.scheduledAt >= windowStart && $0.scheduledAt <= ctx.now }
            return (recent.count >= 3 && recent.allSatisfy { $0.joined }) ? [:] : nil
        case .traveller:
            return PlaceClustering.places(events.compactMap { $0.location }).count >= 5 ? [:] : nil
        case .international:
            let countries = Set(events.compactMap { ($0.location?.countryCode ?? $0.location?.country)?.uppercased() })
            return countries.count >= 2 ? ["countries": countries.sorted().joined(separator: ",")] : nil
        case .newTerritory:
            let ordered = events.sorted { $0.startedAt < $1.startedAt }
            var seen: [String] = []
            for e in ordered {
                guard let city = e.location?.locality, !city.isEmpty else { continue }
                if !seen.contains(city) {
                    seen.append(city)
                    if seen.count >= 2 { return ["city": city] }
                }
            }
            return nil
        case .earlyBird:
            return events.contains(where: { (4..<7).contains(cal.component(.hour, from: $0.startedAt)) }) ? [:] : nil
        case .nightShift:
            return events.contains(where: { (0..<4).contains(cal.component(.hour, from: $0.startedAt)) }) ? [:] : nil
        case .collector:
            return ctx.ownedCosmetics >= 5 ? [:] : nil
        }
    }

    /// Progress toward a not-yet-earned achievement, for the trophy room.
    public static func progress(_ id: AchievementID, _ ctx: AchievementContext) -> AchievementProgress? {
        let cal = ctx.calendar
        switch id {
        case .sevenDay:
            let days = Set(ctx.events.map { DayKey($0.startedAt, calendar: cal) })
            let s = CalendarMath.streaks(days: days, today: DayKey(ctx.now, calendar: cal), calendar: cal)
            return AchievementProgress(current: min(7, max(s.current, 0)), target: 7)
        case .monthlyRegular:
            let month = MonthKey(ctx.now, calendar: cal)
            let days = Set(ctx.events.filter { MonthKey($0.startedAt, calendar: cal) == month }.map { DayKey($0.startedAt, calendar: cal) })
            return AchievementProgress(current: days.count, target: 25)
        case .poopPals:
            return AchievementProgress(current: ctx.completedSocialSessions, target: 10)
        case .partyAnimal:
            return AchievementProgress(current: Set(ctx.events.compactMap { $0.partyID }).count, target: 3)
        case .traveller:
            return AchievementProgress(current: PlaceClustering.places(ctx.events.compactMap { $0.location }).count, target: 5)
        case .international:
            return AchievementProgress(current: Set(ctx.events.compactMap { ($0.location?.countryCode ?? $0.location?.country)?.uppercased() }).count, target: 2)
        case .collector:
            return AchievementProgress(current: ctx.ownedCosmetics, target: 5)
        default:
            return nil
        }
    }

    /// 5 distinct days within a 7-day span that each have a log within ±30 min of the same time of day.
    static func clockwork(_ events: [PoopEvent], calendar: Calendar) -> Bool {
        let recent = events.sorted { $0.startedAt > $1.startedAt }.prefix(400)
        let items = recent.map { (day: DayKey($0.startedAt, calendar: calendar), minute: CalendarMath.minutesFromMidnight($0.startedAt, calendar: calendar)) }
        for anchor in items {
            let earliest = anchor.day.adding(days: -6, calendar: calendar)
            var days = Set<DayKey>()
            for other in items where other.day >= earliest && other.day <= anchor.day {
                let diff = abs(other.minute - anchor.minute)
                if min(diff, 1440 - diff) <= 30 { days.insert(other.day) }
            }
            if days.count >= 5 { return true }
        }
        return false
    }
}
