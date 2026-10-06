import Foundation

/// Concise, deadpan product copy. Picks are deterministic per seed so a screen doesn't
/// flicker between lines on re-render.
public enum Copy {
    public static let tagline = "A serious app for unserious business."

    static let started = ["Excellent.", "Carry on.", "The throne awaits.", "Godspeed.", "Very good."]
    static let complete = ["Respectable.", "Efficient.", "A performance.", "Noted.", "Well done, probably."]
    static let longComplete = ["That was a commitment.", "A whole saga.", "Was there Wi-Fi?"]
    static let instant = ["Logged. No questions.", "Recorded.", "Filed away."]
    static let joined = ["You're not alone anymore.", "Strength in numbers.", "Synchronized."]
    static let zeroToday = ["Nothing yet. Suspense.", "A clean slate.", "Quiet so far."]
    static let manyToday = ["That's information.", "Busy day.", "A productive one."]

    static func pick(_ list: [String], seed: Int) -> String {
        guard !list.isEmpty else { return "" }
        let i = ((seed % list.count) + list.count) % list.count
        return list[i]
    }

    public static func sessionStarted(seed: Int) -> String { pick(started, seed: seed) }

    public static func sessionComplete(duration: TimeInterval, seed: Int) -> String {
        duration > 15 * 60 ? pick(longComplete, seed: seed) : pick(complete, seed: seed)
    }

    public static func instantLogged(seed: Int) -> String { pick(instant, seed: seed) }
    public static func joinedYou(seed: Int) -> String { pick(joined, seed: seed) }

    public static func todayLine(count: Int, seed: Int) -> String {
        count == 0 ? pick(zeroToday, seed: seed) : pick(manyToday, seed: seed)
    }

    public static func seed(_ id: UUID) -> Int {
        id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    }
}
