import Foundation

// This file is compiled into BOTH the app and the Notification Service Extension.

/// What a ping means. Pings are short-lived records in the CloudKit *public* database that carry
/// only an opaque recipient token, a kind, an optional encrypted payload and an expiry.
/// They exist purely to produce real push alerts without a developer backend.
public enum PingKind: String, Codable, CaseIterable, Sendable {
    case poopStart, poopInstant
    case pwmInvite, pwmJoin
    case partyInvite
    case friendRequest, friendAccept, friendComplete

    public static let poopKinds: [PingKind] = [.poopStart, .poopInstant]
    public static let pwmKinds: [PingKind] = [.pwmInvite, .pwmJoin]
    public static let partyKinds: [PingKind] = [.partyInvite]
    public static let handshakeKinds: [PingKind] = [.friendAccept, .friendComplete]

    /// How long the public record lives before the sender deletes it.
    public var lifetime: TimeInterval {
        switch self {
        case .poopStart, .poopInstant, .pwmJoin: return 2 * 3600
        case .pwmInvite: return 3 * 3600
        case .partyInvite: return 7 * 24 * 3600
        case .friendRequest, .friendAccept, .friendComplete: return 7 * 24 * 3600
        }
    }

    public var notificationCategory: String {
        switch self {
        case .pwmInvite: return NotificationCategory.pwmInvite
        case .partyInvite: return NotificationCategory.partyInvite
        case .friendRequest: return NotificationCategory.friendRequest
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
    public static let longSession = "SF_LONG_SESSION"

    public static let actionJoin = "SF_ACTION_JOIN"
    public static let actionDone = "SF_ACTION_DONE"
    public static let actionView = "SF_ACTION_VIEW"
}

/// Field names of the public `Ping` record type.
public enum PingField {
    public static let recordType = "Ping"
    public static let to = "to"
    public static let kind = "kind"
    public static let from = "from"
    public static let ref = "ref"
    public static let exp = "exp"
}

/// Decrypted payload of a ping. All fields optional; which ones are set depends on the kind.
public struct PingPayload: Codable, Hashable, Sendable {
    // Identity (friend handshake)
    public var uid: String?
    public var handle: String?
    public var color: String?
    public var avatar: String?
    public var cosmetic: String?
    public var inbox: String?
    public var pairKey: String?
    public var shareURL: String?
    // Live
    public var sessionID: String?
    public var partyID: String?
    public var groupID: String?
    public var title: String?
    public var at: Date?

    public init(uid: String? = nil, handle: String? = nil, color: String? = nil, avatar: String? = nil, cosmetic: String? = nil, inbox: String? = nil, pairKey: String? = nil, shareURL: String? = nil, sessionID: String? = nil, partyID: String? = nil, groupID: String? = nil, title: String? = nil, at: Date? = nil) {
        self.uid = uid
        self.handle = handle
        self.color = color
        self.avatar = avatar
        self.cosmetic = cosmetic
        self.inbox = inbox
        self.pairKey = pairKey
        self.shareURL = shareURL
        self.sessionID = sessionID
        self.partyID = partyID
        self.groupID = groupID
        self.title = title
        self.at = at
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> PingPayload {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(PingPayload.self, from: data)
    }
}

/// Symmetric sealing of ping payloads (AES-GCM in the app; a fake in Linux tests).
public protocol PayloadSealer {
    func seal(_ plaintext: Data, keyBase64URL: String) throws -> String
    func open(_ sealed: String, keyBase64URL: String) throws -> Data
}

public extension PayloadSealer {
    func seal(_ payload: PingPayload, keyBase64URL: String) throws -> String {
        try seal(try payload.encoded(), keyBase64URL: keyBase64URL)
    }

    func openPayload(_ sealed: String, keyBase64URL: String) throws -> PingPayload {
        try PingPayload.decode(try open(sealed, keyBase64URL: keyBase64URL))
    }
}

// MARK: - Directory shared with the Notification Service Extension

/// Maps my inbox tokens to who is behind them, so the extension can turn an anonymous ping into
/// "💩 @lee is pooping" on-device. Written by the app into the App Group container.
public struct PingDirectory: Codable, Hashable, Sendable {
    public enum EntryKind: String, Codable, Sendable { case friend, group, invite }

    public struct Entry: Codable, Hashable, Sendable {
        public var kind: EntryKind
        /// Friend handle, group name, or empty for invites.
        public var title: String
        /// Group only: sender's group token -> handle label.
        public var members: [String: String]
        /// Key to open `ref` payloads (pair key, group key, or invite secret).
        public var key: String?
        /// Muted entries still deliver (iOS can't drop pushes) but arrive silently.
        public var muted: Bool

        public init(kind: EntryKind, title: String, members: [String: String] = [:], key: String? = nil, muted: Bool = false) {
            self.kind = kind
            self.title = title
            self.members = members
            self.key = key
            self.muted = muted
        }
    }

    public var entries: [String: Entry]
    public var lockScreenPrivate: Bool
    public var quietHoursEnabled: Bool
    public var quietStartMinutes: Int
    public var quietEndMinutes: Int
    public var updatedAt: Date

    public init(entries: [String: Entry] = [:], lockScreenPrivate: Bool = false, quietHoursEnabled: Bool = false, quietStartMinutes: Int = 23 * 60, quietEndMinutes: Int = 7 * 60, updatedAt: Date = Date()) {
        self.entries = entries
        self.lockScreenPrivate = lockScreenPrivate
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.updatedAt = updatedAt
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

public enum NotificationTextBuilder {
    public static let appName = "ShittyFriends"

    /// Builds the visible alert for a ping. `sender` is the resolved handle (without "@") if known.
    public static func text(kind: PingKind, entry: PingDirectory.Entry?, senderToken: String?, payload: PingPayload?, privateMode: Bool, quiet: Bool) -> NotificationText {
        let isGroup = entry?.kind == .group
        var sender: String?
        if isGroup, let t = senderToken { sender = entry?.members[t] }
        if entry?.kind == .friend { sender = entry.map { "@" + $0.title } }
        if kind == .friendRequest || kind == .friendAccept || kind == .friendComplete, let h = payload?.handle { sender = "@" + h }
        let who = sender ?? "A shitty friend"
        let groupName = isGroup ? entry?.title : nil

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
                let partyTitle = payload?.title ?? "Poop Party"
                body = groupName.map { "\(partyTitle) · \($0)" } ?? partyTitle
            }
        case .friendRequest:
            title = "\(who) wants to be shitty friends"
            body = "Open to accept."
        case .friendAccept:
            title = "\(who) accepted"
            body = "Finishing the handshake…"
        case .friendComplete:
            title = "You're shitty friends with \(who)"
            body = "Histories unlocked."
        }
        if let g = groupName, !privateMode, kind != .poopStart, kind != .poopInstant, kind != .partyInvite {
            body = body.isEmpty ? g : "\(body) · \(g)"
        }
        let thread = groupName ?? sender ?? "shittyfriends"
        return NotificationText(title: title, body: body, category: kind.notificationCategory, threadID: thread, silent: quiet || (entry?.muted ?? false))
    }
}
