import Foundation

/// Private, synced across the user's devices (Private zone). Never shared.
public struct AppSettings: Codable, Hashable, Sendable {
    // Global notification switches
    public var notifyFriendPoops: Bool
    public var notifyPWM: Bool
    public var notifyParties: Bool
    public var notifyAchievements: Bool
    public var dailySummary: Bool
    public var weeklyReport: Bool
    public var monthlyHighlights: Bool

    // Quiet hours (minutes from midnight, local time). During quiet hours alerts arrive silently.
    public var quietHoursEnabled: Bool
    public var quietStartMinutes: Int
    public var quietEndMinutes: Int

    /// Lock-screen privacy: "@lee checked in" instead of "💩 @lee is pooping".
    public var lockScreenPrivate: Bool

    // Location
    public var attachLocationByDefault: Bool
    public var locationPrompted: Bool

    /// "Still pooping?" reminder after 30 minutes.
    public var longSessionReminder: Bool

    /// People I blocked: their requests/invites are ignored and they can't be re-added by accident.
    public var blockedUserIDs: [String]

    public var updatedAt: Date

    public init() {
        notifyFriendPoops = true
        notifyPWM = true
        notifyParties = true
        notifyAchievements = true
        dailySummary = false
        weeklyReport = true
        monthlyHighlights = true
        quietHoursEnabled = false
        quietStartMinutes = 23 * 60
        quietEndMinutes = 7 * 60
        lockScreenPrivate = false
        attachLocationByDefault = false
        locationPrompted = false
        longSessionReminder = true
        blockedUserIDs = []
        updatedAt = Date(timeIntervalSince1970: 0)
    }

    /// True if `minutes` (from local midnight) falls inside quiet hours. Handles ranges across midnight.
    public func isQuiet(minutesFromMidnight minutes: Int) -> Bool {
        guard quietHoursEnabled, quietStartMinutes != quietEndMinutes else { return false }
        if quietStartMinutes < quietEndMinutes {
            return minutes >= quietStartMinutes && minutes < quietEndMinutes
        }
        return minutes >= quietStartMinutes || minutes < quietEndMinutes
    }
}
