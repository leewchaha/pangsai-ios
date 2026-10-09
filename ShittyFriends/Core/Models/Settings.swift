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
    /// Last known handle per blocked user id, so the Blocked list stays readable after their
    /// cached profile is gone.
    public var blockedHandles: [String: String]
    /// IANA time zone of the last device that saved settings; the server uses it for quiet hours.
    public var timeZoneID: String

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
        attachLocationByDefault = true
        locationPrompted = false
        longSessionReminder = true
        blockedUserIDs = []
        blockedHandles = [:]
        timeZoneID = TimeZone.current.identifier
        updatedAt = Date(timeIntervalSince1970: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case notifyFriendPoops, notifyPWM, notifyParties, notifyAchievements, dailySummary, weeklyReport, monthlyHighlights
        case quietHoursEnabled, quietStartMinutes, quietEndMinutes, lockScreenPrivate
        case attachLocationByDefault, locationPrompted, longSessionReminder, blockedUserIDs, blockedHandles, timeZoneID, updatedAt
    }

    /// Tolerant decoding: a settings record written by an older app version keeps its values and
    /// takes defaults for fields it doesn't know, instead of failing (and resetting everything).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        notifyFriendPoops = (try? c.decodeIfPresent(Bool.self, forKey: .notifyFriendPoops)) ?? d.notifyFriendPoops
        notifyPWM = (try? c.decodeIfPresent(Bool.self, forKey: .notifyPWM)) ?? d.notifyPWM
        notifyParties = (try? c.decodeIfPresent(Bool.self, forKey: .notifyParties)) ?? d.notifyParties
        notifyAchievements = (try? c.decodeIfPresent(Bool.self, forKey: .notifyAchievements)) ?? d.notifyAchievements
        dailySummary = (try? c.decodeIfPresent(Bool.self, forKey: .dailySummary)) ?? d.dailySummary
        weeklyReport = (try? c.decodeIfPresent(Bool.self, forKey: .weeklyReport)) ?? d.weeklyReport
        monthlyHighlights = (try? c.decodeIfPresent(Bool.self, forKey: .monthlyHighlights)) ?? d.monthlyHighlights
        quietHoursEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled)) ?? d.quietHoursEnabled
        quietStartMinutes = (try? c.decodeIfPresent(Int.self, forKey: .quietStartMinutes)) ?? d.quietStartMinutes
        quietEndMinutes = (try? c.decodeIfPresent(Int.self, forKey: .quietEndMinutes)) ?? d.quietEndMinutes
        lockScreenPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .lockScreenPrivate)) ?? d.lockScreenPrivate
        attachLocationByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .attachLocationByDefault)) ?? d.attachLocationByDefault
        locationPrompted = (try? c.decodeIfPresent(Bool.self, forKey: .locationPrompted)) ?? d.locationPrompted
        longSessionReminder = (try? c.decodeIfPresent(Bool.self, forKey: .longSessionReminder)) ?? d.longSessionReminder
        blockedUserIDs = (try? c.decodeIfPresent([String].self, forKey: .blockedUserIDs)) ?? d.blockedUserIDs
        blockedHandles = (try? c.decodeIfPresent([String: String].self, forKey: .blockedHandles)) ?? d.blockedHandles
        timeZoneID = (try? c.decodeIfPresent(String.self, forKey: .timeZoneID)) ?? d.timeZoneID
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? d.updatedAt
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
