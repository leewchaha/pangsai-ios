import Foundation

// This file is compiled into BOTH the app and the Notification Service Extension.

/// What a push alert is about. The server (Cloud Functions) sends `sf_kind` with one of these raw
/// values; the extension rewrites the alert text on-device for lock-screen privacy and quiet hours.
public enum PingKind: String, Codable, CaseIterable, Sendable {
    case poopStart, poopInstant
    case pwmInvite, pwmJoin
    case partyInvite
    case friendRequest, friendComplete
    case groupJoinRequest, groupJoined

    public static let poopKinds: [PingKind] = [.poopStart, .poopInstant]
    public static let pwmKinds: [PingKind] = [.pwmInvite, .pwmJoin]
    public static let partyKinds: [PingKind] = [.partyInvite]

    public var notificationCategory: String {
        switch self {
        case .pwmInvite: return NotificationCategory.pwmInvite
        case .partyInvite: return NotificationCategory.partyInvite
        case .friendRequest: return NotificationCategory.friendRequest
        case .groupJoinRequest: return NotificationCategory.groupRequest
        default: return NotificationCategory.general
        }
    }
}

public enum NotificationCategory {
    public static let general = "SF_GENERAL"
    public static let pwmInvite = "SF_PWM_INVITE"
    public static let partyInvite = "SF_PARTY_INVITE"
    public static let partyStart = "SF_PARTY_START"
    public static let friendRequest = "SF_FRIEND_REQUEST"
    public static let groupRequest = "SF_GROUP_REQUEST"
    public static let longSession = "SF_LONG_SESSION"

    public static let actionJoin = "SF_ACTION_JOIN"
    public static let actionDone = "SF_ACTION_DONE"
    public static let actionView = "SF_ACTION_VIEW"
}

/// Data keys of a push (set by the Cloud Functions, read by the app and the extension).
public enum PushField {
    public static let kind = "sf_kind"
    public static let sender = "sf_sender"
    public static let group = "sf_group"
    public static let groupID = "sf_group_id"
    public static let space = "sf_space"
    public static let session = "sf_session"
    public static let party = "sf_party"
    public static let title = "sf_title"
}

// MARK: - Directory shared with the Notification Service Extension

/// The few settings the extension needs to finish an alert on-device: lock-screen privacy and quiet
/// hours. (Per-friend / per-group levels are applied by the server before anything is sent.)
public struct PingDirectory: Codable, Hashable, Sendable {
    public var lockScreenPrivate: Bool
    public var quietHoursEnabled: Bool
    public var quietStartMinutes: Int
    public var quietEndMinutes: Int
    public var updatedAt: Date

    public init(lockScreenPrivate: Bool = false, quietHoursEnabled: Bool = false, quietStartMinutes: Int = 23 * 60, quietEndMinutes: Int = 7 * 60, updatedAt: Date = Date()) {
        self.lockScreenPrivate = lockScreenPrivate
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.updatedAt = updatedAt
    }

    public init(settings: AppSettings, now: Date = Date()) {
        self.init(lockScreenPrivate: settings.lockScreenPrivate, quietHoursEnabled: settings.quietHoursEnabled, quietStartMinutes: settings.quietStartMinutes, quietEndMinutes: settings.quietEndMinutes, updatedAt: now)
    }

    public func isQuiet(minutesFromMidnight m: Int) -> Bool {
        guard quietHoursEnabled, quietStartMinutes != quietEndMinutes else { return false }
        if quietStartMinutes < quietEndMinutes { return m >= quietStartMinutes && m < quietEndMinutes }
        return m >= quietStartMinutes || m < quietEndMinutes
    }

    public static let fileName = "ping-directory.json"

    public func write(to directory: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(self)
        try data.write(to: directory.appendingPathComponent(PingDirectory.fileName), options: [.atomic])
    }

    public static func read(from directory: URL) -> PingDirectory? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PingDirectory.self, from: data)
    }
}

// MARK: - Notification text

public struct NotificationText: Hashable, Sendable {
    public var title: String
    public var body: String
    public var category: String
    public var threadID: String
    public var silent: Bool
}

/// Builds the visible alert for a push. The same copy lives in `firebase/functions/src/index.ts`
/// (the server's fallback if the extension can't run).
public enum NotificationTextBuilder {
    public static let appName = "ShittyFriends"

    /// `sender` is the handle (without "@") if known.
    public static func text(kind: PingKind, sender: String?, groupName: String?, partyTitle: String? = nil, privateMode: Bool, quiet: Bool) -> NotificationText {
        let who = sender.map { "@" + $0 } ?? "A shitty friend"
        var title: String
        var body: String
        switch kind {
        case .poopStart:
            title = privateMode ? appName : "💩 \(who) is pooping"
            body = privateMode ? "\(who) checked in" : (groupName.map { "in \($0)" } ?? "Right now.")
        case .poopInstant:
            title = privateMode ? appName : "💩 \(who) just pooped"
            body = privateMode ? "\(who) checked in" : (groupName.map { "in \($0)" } ?? "Logged.")
        case .pwmInvite:
            title = privateMode ? appName : "💩 \(who) wants to poop with you"
            body = privateMode ? "\(who) sent an invite" : "JOIN"
        case .pwmJoin:
            title = privateMode ? appName : "\(who) joined you."
            body = privateMode ? "\(who) checked in" : "You're not alone anymore."
        case .partyInvite:
            title = privateMode ? appName : "🚨 \(who) scheduled a Poop Party"
            if privateMode {
                body = "\(who) sent an invite"
            } else {
                let t = partyTitle ?? "Poop Party"
                body = groupName.map { "\(t) · \($0)" } ?? t
            }
        case .friendRequest:
            title = privateMode ? appName : "\(who) wants to be shitty friends"
            body = privateMode ? "\(who) sent a friend request" : "Open to accept."
        case .friendComplete:
            title = privateMode ? appName : "You're shitty friends with \(who)"
            body = privateMode ? "\(who) is now a friend" : "Histories unlocked."
        case .groupJoinRequest:
            title = privateMode ? appName : "\(who) wants to join \(groupName ?? "your group")"
            body = privateMode ? "\(who) asked to join a group" : "Open the group to approve."
        case .groupJoined:
            title = privateMode ? appName : "You're in \(groupName ?? "the group")"
            body = privateMode ? "A group let you in" : "Group activity only. Full history stays between friends."
        }
        if let g = groupName, !privateMode, kind == .pwmInvite || kind == .pwmJoin {
            body = "\(body) · \(g)"
        }
        let thread = groupName ?? sender.map { "@" + $0 } ?? "shittyfriends"
        return NotificationText(title: title, body: body, category: kind.notificationCategory, threadID: thread, silent: quiet)
    }
}
