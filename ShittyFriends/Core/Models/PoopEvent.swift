import Foundation

public enum PoopSource: String, Codable, CaseIterable, Sendable {
    /// Single tap: live session with a timer.
    case timed
    /// Double tap: instant log, no live session.
    case instant
    /// Added later from history. Never produces live presence or "is pooping" alerts.
    case manual
}

public struct PoopLocation: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Human label ("Home", "TPU", "Toyama Station"). Editable by the owner.
    public var placeName: String?
    public var locality: String?
    public var country: String?
    public var countryCode: String?
    public var accuracy: Double?
    public var capturedAt: Date

    public init(latitude: Double, longitude: Double, placeName: String? = nil, locality: String? = nil, country: String? = nil, countryCode: String? = nil, accuracy: Double? = nil, capturedAt: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.locality = locality
        self.country = country
        self.countryCode = countryCode
        self.accuracy = accuracy
        self.capturedAt = capturedAt
    }

    /// Best short label for UI.
    public var label: String {
        if let p = placeName, !p.isEmpty { return p }
        if let l = locality, !l.isEmpty { return l }
        if let c = country, !c.isEmpty { return c }
        return String(format: "%.3f, %.3f", latitude, longitude)
    }

    /// Great-circle distance in meters.
    public func distance(to other: PoopLocation) -> Double {
        GeoMath.distance(lat1: latitude, lon1: longitude, lat2: other.latitude, lon2: other.longitude)
    }
}

public enum GeoMath {
    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// One poop. The +1 exists from the moment this record exists; timers never decide whether it counts.
public struct PoopEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: PoopSource
    /// The poop timestamp. For timed sessions this is the session start.
    public var startedAt: Date
    /// Timed: set on DONE (nil while live). Manual: optional startedAt + duration. Instant: nil.
    public var endedAt: Date?
    public var location: PoopLocation?
    /// Poop With Me session this poop belongs to.
    public var pwmSessionID: UUID?
    /// Poop Party this poop belongs to.
    public var partyID: UUID?
    /// True once the owner corrected times or location after the fact.
    public var manuallyAdjusted: Bool
    /// Whether the event is mirrored into the user's groups.
    public var sharedToGroups: Bool
    /// Points earned by tapping during this session, in half-point units.
    public var halfPoints: Int
    public var taps: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), source: PoopSource, startedAt: Date, endedAt: Date? = nil, location: PoopLocation? = nil, pwmSessionID: UUID? = nil, partyID: UUID? = nil, manuallyAdjusted: Bool = false, sharedToGroups: Bool = true, halfPoints: Int = 0, taps: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.location = location
        self.pwmSessionID = pwmSessionID
        self.partyID = partyID
        self.manuallyAdjusted = manuallyAdjusted
        self.sharedToGroups = sharedToGroups
        self.halfPoints = halfPoints
        self.taps = taps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var timestamp: Date { startedAt }

    /// Live = a timed session that has not been ended.
    public var isLive: Bool { source == .timed && endedAt == nil }

    /// Recorded duration (nil for instant logs, live sessions, or manual logs without a duration).
    public var duration: TimeInterval? {
        guard source != .instant, let end = endedAt else { return nil }
        return max(0, end.timeIntervalSince(startedAt))
    }

    public func elapsed(now: Date) -> TimeInterval {
        if let d = duration { return d }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Durations past this are almost certainly a forgotten DONE. Shown with a "fix?" affordance
    /// and excluded from longest-session stats. Never auto-deleted.
    public static let suspiciousDuration: TimeInterval = 60 * 60

    public func isSuspicious(now: Date) -> Bool {
        guard source == .timed else { return false }
        return elapsed(now: now) > PoopEvent.suspiciousDuration
    }

    public var points: Double { Double(halfPoints) / 2 }
}

/// Minimal shape every stats/highlights function needs. Lets the same logic run over
/// my own events, a friend's events, and group-mirrored events.
public protocol PoopLike {
    var startedAt: Date { get }
    var endedAt: Date? { get }
    var source: PoopSource { get }
    var location: PoopLocation? { get }
    var pwmSessionID: UUID? { get }
    var partyID: UUID? { get }
}

extension PoopEvent: PoopLike {}
