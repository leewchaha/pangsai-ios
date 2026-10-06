import Foundation

/// Three-step friend handshake over the anonymous ping channel. CloudKit share operations happen in
/// the platform layer between these steps; the store only records state.
///
///   B scans A's invite      -> `beginFriendRequest`      -> ping friendRequest (to A's invite token)
///   A taps ACCEPT           -> `acceptFriendRequest`     -> platform shares A's history with B, ping friendAccept
///   B gets friendAccept     -> platform accepts A's share + shares B's history -> `completeAsRequester`, ping friendComplete
///   A gets friendComplete   -> platform accepts B's share -> `completeAsAccepter`
public extension Store {
    enum HandshakeError: Error, Equatable {
        case notSignedIn
        case ownInvite
        case blocked
        case alreadyFriends
        case unknownRequest
        case unknownLink
    }

    /// B side. Creates (or reuses) a pending link for this invite and returns the request ping to send.
    func beginFriendRequest(_ invite: FriendInvitePayload) throws -> (link: FriendLink, ping: OutgoingPing) {
        guard userID != nil else { throw HandshakeError.notSignedIn }
        if my.invites[invite.t] != nil { throw HandshakeError.ownInvite }
        let link = addRequestedLink(invite: invite, myInbox: TokenFactory.make(), pairKey: TokenFactory.makeKeyData().base64URLEncodedString())
        let ping = PingPlanner.friendRequest(invite: invite, link: link, store: self, now: clock())
        return (link, ping)
    }

    /// A side. Turns a request into a link that is waiting for their share. The platform then adds them
    /// to my history share and sends `PingPlanner.friendAccept` with the share URL.
    func acceptFriendRequest(_ requestID: String) throws -> FriendLink {
        guard userID != nil else { throw HandshakeError.notSignedIn }
        guard let req = my.requests[requestID] else { throw HandshakeError.unknownRequest }
        let uid = req.person.id
        if isBlocked(uid) {
            dismissRequest(requestID)
            throw HandshakeError.blocked
        }
        if let existing = friendLink(for: uid), existing.status == .active {
            dismissRequest(requestID)
            throw HandshakeError.alreadyFriends
        }
        let now = clock()
        // If I had already accepted them once (e.g. retry), keep the same tokens.
        var link = friendLink(for: uid) ?? FriendLink(userID: uid, person: req.person, status: .awaitingTheirShare, myInbox: TokenFactory.make(), pairKey: req.pairKey, createdAt: now, updatedAt: now)
        link.person = req.person
        link.theirInbox = req.theirInbox
        link.pairKey = req.pairKey
        link.status = .awaitingTheirShare
        upsertFriendLink(link)
        dismissRequest(requestID)
        return my.friendLinks[link.id] ?? link
    }

    /// B side, after the platform accepted their share and shared my history with them.
    func completeAsRequester(linkID: UUID, person: PersonRef, theirInbox: InboxToken, shareURL: String) throws {
        guard var link = my.friendLinks[linkID] else { throw HandshakeError.unknownLink }
        link.userID = person.id
        link.person = person
        link.theirInbox = theirInbox
        link.theirShareURL = shareURL
        link.status = .active
        upsertFriendLink(link)
    }

    /// A side, after the platform accepted their share.
    func completeAsAccepter(linkID: UUID, shareURL: String) throws {
        guard var link = my.friendLinks[linkID] else { throw HandshakeError.unknownLink }
        link.theirShareURL = shareURL
        link.status = .active
        upsertFriendLink(link)
    }

    /// Cancel a request I sent (B side) or a pending acceptance (A side).
    func cancelPendingLink(_ linkID: UUID) {
        guard let link = my.friendLinks[linkID], link.status != .active else { return }
        removeFriendLocal(link.id)
    }
}
