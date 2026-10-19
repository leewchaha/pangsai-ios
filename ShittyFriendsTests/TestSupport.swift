import Foundation
@testable import ShittyFriends

/// Deterministic clock + calendar for tests.
final class TestClock {
    var now: Date

    init(_ iso: String = "2026-10-06T08:00:00+09:00") {
        now = TestClock.date(iso)
    }

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

enum TestEnv {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static var calendar: Calendar { CalendarMath.standard(timeZone: tokyo) }

    /// A store with a profile, a known user id, a test clock, and an effect log.
    static func store(clock: TestClock, userID: UserID? = "_me") -> (Store, EffectLog) {
        let store = Store()
        let log = EffectLog()
        store.clock = { clock.now }
        store.calendar = calendar
        store.randomRoll = { 0.99 } // never critical unless a test overrides it
        store.effectHandler = { log.effects.append($0) }
        store.setUserID(userID)
        store.completeOnboarding(handle: "@Lee", avatar: AvatarSpec(), color: .lime)
        log.effects.removeAll()
        return (store, log)
    }
}

final class EffectLog {
    var effects: [Effect] = []

    func contains(_ e: Effect) -> Bool { effects.contains(e) }

    var saves: [RecordRef] {
        effects.compactMap { if case .save(let r) = $0 { return r } else { return nil } }
    }

    var deletes: [RecordRef] {
        effects.compactMap { if case .delete(let r) = $0 { return r } else { return nil } }
    }

    var pings: [PingIntent] {
        effects.compactMap { if case .ping(let p) = $0 { return p } else { return nil } }
    }
}
