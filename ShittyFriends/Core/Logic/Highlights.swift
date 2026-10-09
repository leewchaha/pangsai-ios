import Foundation

public enum HighlightPeriod: String, Codable, CaseIterable, Sendable {
    case day, week, month

    public var title: String {
        switch self {
        case .day: return "TODAY IN SHIT"
        case .week: return "THE WEEK IN SHIT"
        case .month: return "THE MONTH IN SHIT"
        }
    }

    public func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .day: return CalendarMath.dayInterval(date, calendar: calendar)
        case .week: return CalendarMath.weekInterval(date, calendar: calendar)
        case .month: return CalendarMath.monthInterval(date, calendar: calendar)
        }
    }
}

public struct HighlightEvent: Hashable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var source: PoopSource
    public var location: PoopLocation?

    public init(startedAt: Date, endedAt: Date?, source: PoopSource, location: PoopLocation?) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.location = location
    }

    public init<E: PoopLike>(_ e: E) {
        self.init(startedAt: e.startedAt, endedAt: e.endedAt, source: e.source, location: e.location)
    }
}

public struct HighlightParticipant: Hashable, Sendable {
    public var id: UserID
    public var handle: String
    public var color: IdentityColor
    public var events: [HighlightEvent]

    public init(id: UserID, handle: String, color: IdentityColor, events: [HighlightEvent]) {
        self.id = id
        self.handle = handle
        self.color = color
        self.events = events
    }
}

public struct HighlightCard: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case total, throneOccupant, poopBuddies, earlyBird, nightShift, greatIncident, speedRun, wanderer, streak, commonTime
    }

    public var kind: Kind
    public var emoji: String
    public var title: String
    public var headline: String
    public var detail: String
    public var color: IdentityColor
    public var participantIDs: [UserID]

    public var id: String { kind.rawValue + participantIDs.joined(separator: ",") }
}

public enum HighlightsEngine {
    public static func cards(
        for participants: [HighlightParticipant],
        period: HighlightPeriod,
        reference: Date,
        calendar: Calendar,
        isGroup: Bool
    ) -> [HighlightCard] {
        let interval = period.interval(containing: reference, calendar: calendar)
        let people = participants.map { p -> HighlightParticipant in
            var q = p
            q.events = p.events.filter { interval.contains($0.startedAt) }
            return q
        }.sorted { $0.handle.lowercased() < $1.handle.lowercased() }

        var cards: [HighlightCard] = []
        let total = people.reduce(0) { $0 + $1.events.count }
        guard total > 0 else { return [] }

        // Total
        cards.append(HighlightCard(
            kind: .total, emoji: "💩", title: "TOTAL", headline: "\(total)",
            detail: totalCopy(total: total, isGroup: isGroup),
            color: .sun, participantIDs: []
        ))

        // Throne occupant
        if people.count > 1, let top = argmax(people, { $0.events.count }), top.events.count > 0 {
            cards.append(HighlightCard(kind: .throneOccupant, emoji: "👑", title: "THRONE OCCUPANT", headline: "@\(top.handle)", detail: "\(top.events.count) logs", color: top.color, participantIDs: [top.id]))
        }

        // Poop buddies: most logs within 10 minutes of each other.
        if people.count > 1 {
            var best: (a: HighlightParticipant, b: HighlightParticipant, n: Int)?
            for i in 0..<people.count {
                for j in (i + 1)..<people.count {
                    let n = nearSimultaneous(people[i].events, people[j].events, window: 600)
                    if n >= 2, n > (best?.n ?? 0) { best = (people[i], people[j], n) }
                }
            }
            if let b = best {
                cards.append(HighlightCard(kind: .poopBuddies, emoji: "🤝", title: "POOP BUDDIES", headline: "@\(b.a.handle) + @\(b.b.handle)", detail: "\(b.n) times within 10 min", color: b.a.color, participantIDs: [b.a.id, b.b.id]))
            }
        }

        // Early bird
        let early = { (p: HighlightParticipant) in p.events.filter { calendar.component(.hour, from: $0.startedAt) < 8 && calendar.component(.hour, from: $0.startedAt) >= 4 }.count }
        if let top = argmax(people, early), early(top) > 0 {
            cards.append(HighlightCard(kind: .earlyBird, emoji: "🌅", title: "EARLY BIRD", headline: "@\(top.handle)", detail: "\(early(top)) before 08:00", color: top.color, participantIDs: [top.id]))
        }

        // Night shift
        let night = { (p: HighlightParticipant) in p.events.filter { calendar.component(.hour, from: $0.startedAt) < 4 }.count }
        if let top = argmax(people, night), night(top) > 0 {
            cards.append(HighlightCard(kind: .nightShift, emoji: "🌙", title: "NIGHT SHIFT", headline: "@\(top.handle)", detail: "\(night(top)) after midnight", color: top.color, participantIDs: [top.id]))
        }

        // Great incident: busiest day (weekly/monthly only).
        if period != .day {
            var perDay: [DayKey: Int] = [:]
            for p in people { for e in p.events { perDay[DayKey(e.startedAt, calendar: calendar), default: 0] += 1 } }
            if let busiest = perDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), busiest.value >= 3 {
                let weekday = weekdayName(busiest.key.startDate(calendar: calendar), calendar: calendar)
                cards.append(HighlightCard(kind: .greatIncident, emoji: "🔥", title: "THE GREAT \(weekday) INCIDENT", headline: "\(busiest.value)", detail: isGroup ? "group logs in one day" : "logs in one day", color: .tomato, participantIDs: []))
            }
        }

        // Speedrun: shortest completed timed session (>= 20s, under the suspicious threshold).
        var fastest: (p: HighlightParticipant, d: TimeInterval)?
        for p in people {
            for e in p.events where e.source == .timed {
                guard let end = e.endedAt else { continue }
                let d = end.timeIntervalSince(e.startedAt)
                if d >= 20 && d <= PoopEvent.suspiciousDuration && d < (fastest?.d ?? .infinity) { fastest = (p, d) }
            }
        }
        if let f = fastest {
            cards.append(HighlightCard(kind: .speedRun, emoji: "⚡️", title: "SPEEDRUN", headline: "@\(f.p.handle)", detail: StatsCalculator.formatDuration(f.d), color: f.p.color, participantIDs: [f.p.id]))
        }

        // Wanderer: most distinct places.
        let placeCount = { (p: HighlightParticipant) in PlaceClustering.places(p.events.compactMap { $0.location }).count }
        if let top = argmax(people, placeCount), placeCount(top) >= 2 {
            cards.append(HighlightCard(kind: .wanderer, emoji: "🧭", title: "WANDERER", headline: "@\(top.handle)", detail: "\(placeCount(top)) different places", color: top.color, participantIDs: [top.id]))
        }

        // Solo extras
        if people.count == 1, let me = people.first {
            let stats = StatsCalculator.compute(me.events.map { SimpleEvent($0) }, now: reference, calendar: calendar)
            if let window = stats.commonWindowLabel, period != .day {
                cards.append(HighlightCard(kind: .commonTime, emoji: "⏰", title: "PRIME TIME", headline: window, detail: "your most common window", color: me.color, participantIDs: [me.id]))
            }
        }
        return cards
    }

    public static func totalCopy(total: Int, isGroup: Bool) -> String {
        if isGroup {
            switch total {
            case 0..<5: return "A quiet society."
            case 5..<30: return "A functioning society."
            default: return "A thriving civilization."
            }
        }
        switch total {
        case 1: return "That's a start."
        case 2...3: return "That's information."
        default: return "Noted. Permanently."
        }
    }

    static func nearSimultaneous(_ a: [HighlightEvent], _ b: [HighlightEvent], window: TimeInterval) -> Int {
        var used = Set<Int>()
        var n = 0
        for x in a.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let j = b.indices.first(where: { !used.contains($0) && abs(b[$0].startedAt.timeIntervalSince(x.startedAt)) <= window }) {
                used.insert(j)
                n += 1
            }
        }
        return n
    }

    static func argmax(_ people: [HighlightParticipant], _ f: (HighlightParticipant) -> Int) -> HighlightParticipant? {
        var best: HighlightParticipant?
        var bestValue = Int.min
        for p in people {
            let v = f(p)
            if v > bestValue { best = p; bestValue = v }
        }
        return best
    }

    static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
        let w = calendar.component(.weekday, from: date)
        return names[max(0, min(6, w - 1))]
    }
}

/// Adapter so highlight events can reuse PoopLike-based stats.
struct SimpleEvent: PoopLike {
    var startedAt: Date
    var endedAt: Date?
    var source: PoopSource
    var location: PoopLocation?
    var pwmSessionID: UUID? { nil }
    var partyID: UUID? { nil }
    var manuallyAdjusted: Bool { false }
    var imported: Bool { false }

    init(_ e: HighlightEvent) {
        startedAt = e.startedAt
        endedAt = e.endedAt
        source = e.source
        location = e.location
    }
}
