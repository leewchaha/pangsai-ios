import Foundation

/// The glossy 3D object that represents an achievement.
public enum TrophyObject: String, Codable, CaseIterable, Sendable {
    case goldenToilet, jeweledPaper, crown, chromePoop, meltingClock, twinToilets, passportPoop, flamingThrone, crystalRoll, partyHat, globe, flag, sun, moon
}

public enum AchievementCategory: String, Codable, CaseIterable, Sendable {
    case consistency, social, location, time, collection

    public var title: String {
        switch self {
        case .consistency: return "CONSISTENCY"
        case .social: return "SOCIAL"
        case .location: return "LOCATION"
        case .time: return "TIME"
        case .collection: return "COLLECTION"
        }
    }
}

/// None of these ask for more bowel movements. They reward consistency of logging,
/// social rituals, travel and collecting.
public enum AchievementID: String, Codable, CaseIterable, Sendable, Identifiable {
    case firstDrop, sevenDay, monthlyRegular, clockwork
    case firstFriend, poopPals, partyAnimal, perfectAttendance
    case traveller, international, newTerritory
    case earlyBird, nightShift
    case collector

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstDrop: return "First Drop"
        case .sevenDay: return "7 Day Shitter"
        case .monthlyRegular: return "Monthly Regular"
        case .clockwork: return "Clockwork"
        case .firstFriend: return "Shitty Friend"
        case .poopPals: return "Poop Pals"
        case .partyAnimal: return "Party Animal"
        case .perfectAttendance: return "Perfect Attendance"
        case .traveller: return "Traveller"
        case .international: return "International Shitter"
        case .newTerritory: return "New Territory"
        case .earlyBird: return "Early Bird"
        case .nightShift: return "Night Shift"
        case .collector: return "Collector"
        }
    }

    public var detail: String {
        switch self {
        case .firstDrop: return "Logged your first poop. It begins."
        case .sevenDay: return "At least one log on seven consecutive days."
        case .monthlyRegular: return "Logged on 25 different days in one month."
        case .clockwork: return "Logged within the same hour on 5 different days in a week."
        case .firstFriend: return "Became shitty friends with someone."
        case .poopPals: return "Completed 10 Poop With Me sessions."
        case .partyAnimal: return "Joined 3 Poop Parties."
        case .perfectAttendance: return "Joined every party you said yes to (at least 3) in 30 days."
        case .traveller: return "Pooped in 5 different places."
        case .international: return "Logged in two countries."
        case .newTerritory: return "First log in a new city."
        case .earlyBird: return "A log between 4:00 and 7:00."
        case .nightShift: return "A log between midnight and 4:00."
        case .collector: return "Own 5 poop cosmetics."
        }
    }

    public var category: AchievementCategory {
        switch self {
        case .firstDrop, .sevenDay, .monthlyRegular, .clockwork: return .consistency
        case .firstFriend, .poopPals, .partyAnimal, .perfectAttendance: return .social
        case .traveller, .international, .newTerritory: return .location
        case .earlyBird, .nightShift: return .time
        case .collector: return .collection
        }
    }

    public var object: TrophyObject {
        switch self {
        case .firstDrop: return .chromePoop
        case .sevenDay: return .flamingThrone
        case .monthlyRegular: return .goldenToilet
        case .clockwork: return .meltingClock
        case .firstFriend: return .jeweledPaper
        case .poopPals: return .twinToilets
        case .partyAnimal: return .partyHat
        case .perfectAttendance: return .crown
        case .traveller: return .passportPoop
        case .international: return .globe
        case .newTerritory: return .flag
        case .earlyBird: return .sun
        case .nightShift: return .moon
        case .collector: return .crystalRoll
        }
    }
}

public struct AchievementUnlock: Codable, Hashable, Sendable, Identifiable {
    public var id: AchievementID
    public var unlockedAt: Date
    /// Free-form context, e.g. the city for New Territory.
    public var metadata: [String: String]

    public init(id: AchievementID, unlockedAt: Date = Date(), metadata: [String: String] = [:]) {
        self.id = id
        self.unlockedAt = unlockedAt
        self.metadata = metadata
    }
}
