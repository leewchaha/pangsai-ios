import Foundation

/// Contents of a friend invite (QR / link). Holding it only lets someone *request* friendship;
/// the inviter still confirms, and nothing in it identifies the inviter's iCloud account.
public struct FriendInvitePayload: Codable, Hashable, Sendable {
    public var v: Int
    /// Inviter handle
    public var h: String
    /// Inviter color
    public var c: String
    /// Inviter avatar (compact)
    public var a: String
    /// Invite token (public-DB inbox for the request)
    public var t: String
    /// Invite secret (encrypts the request payload)
    public var k: String

    public init(handle: String, color: IdentityColor, avatar: AvatarSpec, token: String, secret: String) {
        v = 1
        h = handle
        c = color.rawValue
        a = avatar.compact
        t = token
        k = secret
    }

    public var color: IdentityColor { IdentityColor(rawValue: c) ?? IdentityColor.stable(for: h) }
    public var avatar: AvatarSpec { AvatarSpec(compact: a) ?? AvatarSpec() }
}

/// Contents of a group invite: the CloudKit share URL plus a preview.
public struct GroupInvitePayload: Codable, Hashable, Sendable {
    public var v: Int
    public var n: String
    public var o: String
    public var c: String
    public var u: String

    public init(name: String, object: GroupObject, color: IdentityColor, shareURL: String) {
        v = 1
        n = name
        o = object.rawValue
        c = color.rawValue
        u = shareURL
    }

    public var object: GroupObject { GroupObject(rawValue: o) ?? .toilet }
    public var color: IdentityColor { IdentityColor(rawValue: c) ?? .violet }
}

public enum DeepLink: Hashable, Sendable {
    case friendInvite(FriendInvitePayload)
    case groupInvite(GroupInvitePayload)
    /// A raw iCloud share URL (https://www.icloud.com/share/...).
    case cloudShare(URL)
    case openSession
    case openParty(UUID)
}

public enum DeepLinkCodec {
    public static let scheme = "shittyfriends"
    /// Optional universal-link host (see web/README). When nil, custom-scheme links are used.
    public static var universalHost: String?

    public static func friendURL(_ p: FriendInvitePayload) -> URL {
        url(path: "friend", payload: p)
    }

    public static func groupURL(_ p: GroupInvitePayload) -> URL {
        url(path: "group", payload: p)
    }

    static func url<T: Encodable>(path: String, payload: T) -> URL {
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let d = data.base64URLEncodedString()
        if let host = universalHost, let u = URL(string: "https://\(host)/\(path)#\(d)") { return u }
        return URL(string: "\(scheme)://\(path)?d=\(d)")!
    }

    public static func parse(_ url: URL) -> DeepLink? {
        let s = url.absoluteString
        if (url.host ?? "").hasSuffix("icloud.com"), s.contains("/share/") { return .cloudShare(url) }

        var path: String?
        var blob: String?
        if url.scheme == scheme {
            path = url.host
            blob = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value
            if path == "session" { return .openSession }
            if path == "party", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value, let uuid = UUID(uuidString: id) {
                return .openParty(uuid)
            }
        } else if url.scheme == "https", let host = universalHost, url.host == host {
            path = url.pathComponents.dropFirst().first
            blob = url.fragment
        }
        guard let p = path, let b = blob, let data = Data(base64URLEncoded: b) else { return nil }
        switch p {
        case "friend":
            guard let payload = try? JSONDecoder().decode(FriendInvitePayload.self, from: data), payload.v == 1 else { return nil }
            return .friendInvite(payload)
        case "group":
            guard let payload = try? JSONDecoder().decode(GroupInvitePayload.self, from: data), payload.v == 1 else { return nil }
            return .groupInvite(payload)
        default:
            return nil
        }
    }

    /// Finds the first ShittyFriends or iCloud-share link in arbitrary pasted text.
    public static func find(in text: String) -> DeepLink? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>()[]"))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            guard token.contains("://"), let url = URL(string: token) else { continue }
            if let link = parse(url) { return link }
        }
        return nil
    }

    public static func friendShareText(handle: String, url: URL) -> String {
        "Become shitty friends with @\(handle) 💩\n\(url.absoluteString)"
    }

    public static func groupShareText(name: String, url: URL) -> String {
        "Join \(name) on ShittyFriends 💩\n\(url.absoluteString)"
    }
}
