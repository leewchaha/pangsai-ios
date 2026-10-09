import Foundation

/// Contents of a friend invite (QR / link). Holding it only lets someone *request* friendship;
/// the inviter still confirms each request (the server checks the token is live and unblocked).
public struct FriendInvitePayload: Codable, Hashable, Sendable {
    public var v: Int
    /// Inviter handle
    public var h: String
    /// Inviter color
    public var c: String
    /// Inviter avatar (compact)
    public var a: String
    /// Invite token (`invites/{token}` on the server)
    public var t: String
    /// Inviter user id (v2). Older (v1) links carry none; the token resolves it.
    public var u: String?

    public init(handle: String, color: IdentityColor, avatar: AvatarSpec, token: String, userID: String?) {
        v = 2
        h = handle
        c = color.rawValue
        a = avatar.compact
        t = token
        u = userID
    }

    public var color: IdentityColor { IdentityColor(rawValue: c) ?? IdentityColor.stable(for: h) }
    public var avatar: AvatarSpec { AvatarSpec(compact: a) ?? AvatarSpec() }

    private enum CodingKeys: String, CodingKey { case v, h, c, a, t, u }

    public init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? d.decode(Int.self, forKey: .v)) ?? 1
        h = try d.decode(String.self, forKey: .h)
        c = (try? d.decode(String.self, forKey: .c)) ?? ""
        a = (try? d.decode(String.self, forKey: .a)) ?? ""
        t = try d.decode(String.self, forKey: .t)
        u = try? d.decodeIfPresent(String.self, forKey: .u)
    }

    /// base64url(JSON) form used in links.
    public var encoded: String {
        ((try? JSONEncoder().encode(self)) ?? Data()).base64URLEncodedString()
    }

    public static func decode(_ s: String) -> FriendInvitePayload? {
        guard let data = Data(base64URLEncoded: s),
              let p = try? JSONDecoder().decode(FriendInvitePayload.self, from: data), p.v >= 1 else { return nil }
        return p
    }
}

/// Contents of a group invite: the join code plus a preview. Opening it asks to join; the owner approves.
public struct GroupInvitePayload: Codable, Hashable, Sendable {
    public var v: Int
    public var n: String
    public var o: String
    public var c: String
    /// Join code (`groupInvites/{code}` on the server).
    public var k: String

    public init(name: String, object: GroupObject, color: IdentityColor, code: String) {
        v = 2
        n = name
        o = object.rawValue
        c = color.rawValue
        k = code
    }

    public var object: GroupObject { GroupObject(rawValue: o) ?? .toilet }
    public var color: IdentityColor { IdentityColor(rawValue: c) ?? .violet }
}

public enum DeepLink: Hashable, Sendable {
    case friendInvite(FriendInvitePayload)
    case groupInvite(GroupInvitePayload)
    case openSession
    case openParty(UUID)
}

public enum DeepLinkCodec {
    public static let scheme = "shittyfriends"
    /// Optional universal-link host. When nil, custom-scheme links are used.
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
        var path: String?
        var blob: String?
        if url.scheme == scheme {
            path = url.host
            blob = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value
            if path == "session" || path == "open-session" { return .openSession }
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
            guard let payload = try? JSONDecoder().decode(FriendInvitePayload.self, from: data) else { return nil }
            return .friendInvite(payload)
        case "group":
            guard let payload = try? JSONDecoder().decode(GroupInvitePayload.self, from: data), payload.v == 2 else { return nil }
            return .groupInvite(payload)
        default:
            return nil
        }
    }

    /// Finds the first ShittyFriends link in arbitrary pasted text.
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
