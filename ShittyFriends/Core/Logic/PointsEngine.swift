import Foundation

/// Point economy for tapping the poop during a timed session.
///
/// Design constraint from the handoff (8.1): points reward *interaction during an existing session*,
/// never more bowel movements. Therefore the daily ceiling is only slightly above one session's cap,
/// so a second or third session in a day adds almost nothing. All values are in half-point units.
public struct PointRules: Codable, Hashable, Sendable {
    /// Taps 1...fullRateTaps earn `fullRate` each.
    public var fullRateTaps: Int = 30
    public var fullRate: Int = 2
    /// Taps up to `reducedRateTaps` earn `reducedRate` each.
    public var reducedRateTaps: Int = 60
    public var reducedRate: Int = 1
    /// Max half-points per session (50 points).
    public var sessionCap: Int = 100
    /// Max half-points per local day (60 points).
    public var dailyCap: Int = 120
    /// Taps closer together than this still animate but earn nothing (auto-clicker guard).
    public var minTapInterval: TimeInterval = 0.06
    /// Chance that an earning tap is critical (+1 point bonus, still capped).
    public var criticalChance: Double = 1.0 / 12.0
    public var criticalBonus: Int = 2
    /// Taps within this window keep the combo alive.
    public var comboWindow: TimeInterval = 0.6

    public init() {}

    public static let standard = PointRules()
}

public struct TapState: Sendable, Hashable {
    public var lastTapAt: Date?
    public var combo: Int

    public init(lastTapAt: Date? = nil, combo: Int = 0) {
        self.lastTapAt = lastTapAt
        self.combo = combo
    }
}

public struct TapOutcome: Sendable, Hashable {
    public var gainedHalfPoints: Int
    public var isCritical: Bool
    public var combo: Int
    /// 0...5, drives escalating visual ridiculousness.
    public var comboLevel: Int
    public var sessionCapped: Bool
    public var dailyCapped: Bool
    public var rateLimited: Bool
}

public enum PointsEngine {
    public static func tap(
        at now: Date,
        sessionTapsBefore: Int,
        sessionHalfPointsBefore: Int,
        dailyHalfPointsBefore: Int,
        state: inout TapState,
        rules: PointRules = .standard,
        roll: Double
    ) -> TapOutcome {
        var rateLimited = false
        if let last = state.lastTapAt {
            let gap = now.timeIntervalSince(last)
            if gap < rules.minTapInterval { rateLimited = true }
            state.combo = gap <= rules.comboWindow ? state.combo + 1 : 1
        } else {
            state.combo = 1
        }
        state.lastTapAt = now

        let tapNumber = sessionTapsBefore + 1
        var base: Int
        if tapNumber <= rules.fullRateTaps {
            base = rules.fullRate
        } else if tapNumber <= rules.reducedRateTaps {
            base = rules.reducedRate
        } else {
            base = 0
        }
        if rateLimited { base = 0 }

        var critical = false
        if base > 0 && roll < rules.criticalChance {
            critical = true
            base += rules.criticalBonus
        }

        let sessionRoom = max(0, rules.sessionCap - sessionHalfPointsBefore)
        let dailyRoom = max(0, rules.dailyCap - dailyHalfPointsBefore)
        let gained = min(base, sessionRoom, dailyRoom)
        if gained == 0 { critical = false }

        let sessionCapped = sessionHalfPointsBefore + gained >= rules.sessionCap
        let dailyCapped = dailyHalfPointsBefore + gained >= rules.dailyCap

        return TapOutcome(
            gainedHalfPoints: gained,
            isCritical: critical,
            combo: state.combo,
            comboLevel: min(5, state.combo / 8),
            sessionCapped: sessionCapped,
            dailyCapped: dailyCapped,
            rateLimited: rateLimited
        )
    }

    /// Whole points available to spend: earned from sessions minus spent on cosmetics.
    public static func balance(events: [PoopEvent], unlocks: [CosmeticUnlock]) -> Int {
        let earnedHalf = events.reduce(0) { $0 + $1.halfPoints }
        let spent = unlocks.reduce(0) { $0 + $1.cost }
        return max(0, earnedHalf / 2 - spent)
    }

    public static func lifetimePoints(events: [PoopEvent]) -> Int {
        events.reduce(0) { $0 + $1.halfPoints } / 2
    }

    /// Half-points already earned on the local day of `date`.
    public static func dailyHalfPoints(events: [PoopEvent], on date: Date, calendar: Calendar) -> Int {
        let day = DayKey(date, calendar: calendar)
        return events.filter { DayKey($0.startedAt, calendar: calendar) == day }.reduce(0) { $0 + $1.halfPoints }
    }
}
