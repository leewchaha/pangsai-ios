import Foundation

/// Social/entertainment statistics. Deliberately no medical interpretation.
public struct PoopStats: Hashable, Sendable {
    public var total: Int = 0
    public var timedCount: Int = 0
    public var instantCount: Int = 0
    public var manualCount: Int = 0
    public var activeDays: Int = 0
    public var averagePerActiveDay: Double = 0
    /// Start hour of the most common 2-hour window, e.g. 8 for 08:00–10:00.
    public var commonWindowStartHour: Int?
    public var longestSession: TimeInterval?
    public var shortestSession: TimeInterval?
    public var mostUsedPlace: String?
    public var uniquePlaces: Int = 0
    public var cities: Int = 0
    public var countries: Int = 0
    public var pwmCount: Int = 0
    public var partyCount: Int = 0
    public var currentStreak: Int = 0
    public var longestStreak: Int = 0

    public init() {}

    public var commonWindowLabel: String? {
        guard let h = commonWindowStartHour else { return nil }
        return String(format: "%02d:00–%02d:00", h, (h + 2) % 24)
    }
}

/// Groups nearby coordinates into places.
public enum PlaceClustering {
    public struct Place: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var label: String
        public var count: Int
    }

    /// Greedy clustering: each location joins the first place within `radius` meters.
    public static func places(_ locations: [PoopLocation], radius: Double = 150) -> [Place] {
        var centers: [(lat: Double, lon: Double, labels: [String: Int], count: Int)] = []
        for loc in locations {
            if let i = centers.firstIndex(where: { GeoMath.distance(lat1: $0.lat, lon1: $0.lon, lat2: loc.latitude, lon2: loc.longitude) <= radius }) {
                let n = Double(centers[i].count)
                centers[i].lat = (centers[i].lat * n + loc.latitude) / (n + 1)
                centers[i].lon = (centers[i].lon * n + loc.longitude) / (n + 1)
                centers[i].count += 1
                centers[i].labels[loc.label, default: 0] += 1
            } else {
                centers.append((loc.latitude, loc.longitude, [loc.label: 1], 1))
            }
        }
        return centers.map { c in
            let label = c.labels.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? ""
            return Place(latitude: c.lat, longitude: c.lon, label: label, count: c.count)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

public enum StatsCalculator {
    public static func compute<E: PoopLike>(_ all: [E], in interval: DateInterval? = nil, now: Date, calendar: Calendar) -> PoopStats {
        let events = interval.map { iv in all.filter { iv.contains($0.startedAt) } } ?? all
        var s = PoopStats()
        s.total = events.count
        s.timedCount = events.filter { $0.source == .timed }.count
        s.instantCount = events.filter { $0.source == .instant }.count
        s.manualCount = events.filter { $0.source == .manual }.count

        let days = Set(events.map { DayKey($0.startedAt, calendar: calendar) })
        s.activeDays = days.count
        s.averagePerActiveDay = days.isEmpty ? 0 : Double(events.count) / Double(days.count)

        var buckets = [Int](repeating: 0, count: 12)
        for e in events {
            let h = calendar.component(.hour, from: e.startedAt)
            buckets[h / 2] += 1
        }
        if let maxCount = buckets.max(), maxCount > 0, let idx = buckets.firstIndex(of: maxCount) {
            s.commonWindowStartHour = idx * 2
        }

        let durations: [TimeInterval] = events.compactMap { e in
            guard e.source == .timed, let end = e.endedAt else { return nil }
            let d = end.timeIntervalSince(e.startedAt)
            return (d >= 0 && d <= PoopEvent.suspiciousDuration) ? d : nil
        }
        s.longestSession = durations.max()
        s.shortestSession = durations.min()

        let locations = events.compactMap { $0.location }
        let places = PlaceClustering.places(locations)
        s.uniquePlaces = places.count
        s.mostUsedPlace = places.first?.label
        s.cities = Set(locations.compactMap { $0.locality?.lowercased() }).count
        s.countries = Set(locations.compactMap { ($0.countryCode ?? $0.country)?.uppercased() }).count

        s.pwmCount = Set(events.compactMap { $0.pwmSessionID }).count
        s.partyCount = Set(events.compactMap { $0.partyID }).count

        // Streaks are always computed over the full history, not just the interval.
        let allDays = Set(all.map { DayKey($0.startedAt, calendar: calendar) })
        let st = CalendarMath.streaks(days: allDays, today: DayKey(now, calendar: calendar), calendar: calendar)
        s.currentStreak = st.current
        s.longestStreak = st.longest
        return s
    }

    public static func count<E: PoopLike>(_ events: [E], on day: DayKey, calendar: Calendar) -> Int {
        events.filter { DayKey($0.startedAt, calendar: calendar) == day }.count
    }

    public static func countsByDay<E: PoopLike>(_ events: [E], calendar: Calendar) -> [DayKey: Int] {
        var out: [DayKey: Int] = [:]
        for e in events { out[DayKey(e.startedAt, calendar: calendar), default: 0] += 1 }
        return out
    }

    public static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// "08m 14s" style used in history rows.
    public static func formatDurationWords(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%02dm %02ds", m, s)
    }
}
