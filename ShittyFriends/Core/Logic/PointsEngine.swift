import Foundation

/// Point economy for tapping the poop during a timed session.
///
/// Every earning tap pays the same rate for as long as the timer runs: no tiers, no per-session cap,
/// no daily cap. The only limit is the auto-clicker guard. Progression is paced by cosmetic prices
/// (see `CosmeticID.price` / `PinShineID.price`). All values are in half-point units.
public struct PointRules: Codable, Hashable, Sendable {
    /// Half-points per earning tap (2 = 1 point).
    public var tapRate: Int = 2
    /// Taps closer together than this still animate but earn nothing (auto-clicker guard).
    public var minTapInterval: TimeInterval = 0.06
    /// Chance that an earning tap is critical (+1 point bonus).
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
    public var rateLimited: Bool
}

public enum PointsEngine {
    public static func tap(
        at now: Date,
        sessionTapsBefore: Int,
        sessionHalfPointsBefore: Int,
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

        var base = rateLimited ? 0 : rules.tapRate

        var critical = false
        if base > 0 && roll < rules.criticalChance {
            critical = true
            base += rules.criticalBonus
        }

        // `sessionHalfPointsBefore` is kept in the signature for callers/tests; sessions are uncapped.
        _ = sessionHalfPointsBefore
        let gained = base
        if gained == 0 { critical = false }

        return TapOutcome(
            gainedHalfPoints: gained,
            isCritical: critical,
            combo: state.combo,
            comboLevel: min(5, state.combo / 8),
            rateLimited: rateLimited
        )
    }

    /// Whole points available to spend: earned from sessions (including points banked from poops
    /// that were deleted later) minus spent on cosmetics.
    public static func balance(events: [PoopEvent], unlocks: [CosmeticUnlock], shineUnlocks: [PinShineUnlock] = [], bankedHalfPoints: Int = 0) -> Int {
        let earnedHalf = events.reduce(0) { $0 + $1.halfPoints } + max(0, bankedHalfPoints)
        let spent = unlocks.reduce(0) { $0 + $1.cost } + shineUnlocks.reduce(0) { $0 + $1.cost }
        return max(0, earnedHalf / 2 - spent)
    }

    public static func lifetimePoints(events: [PoopEvent], bankedHalfPoints: Int = 0) -> Int {
        (events.reduce(0) { $0 + $1.halfPoints } + max(0, bankedHalfPoints)) / 2
    }

}
