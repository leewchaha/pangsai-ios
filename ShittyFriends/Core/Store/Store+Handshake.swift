import Foundation

/// Friend handshake on top of the server's `friendRequests` / `friendships` records. The platform
/// layer writes the records; the store only records state and reacts to what comes back.
///
///   B opens A's invite       -> `beginFriendRequest`     -> platform creates friendRequests/{id}
///   A sees the request       -> `receiveFriendRequest`
///   A taps ACCEPT            -> `acceptFriendRequest`    -> platform creates friendships/{pair}
///   both see the friendship  -> `friendshipConfirmed`    -> link active, histories visible
///   either unfriends/blocks  -> platform deletes the friendship -> `friendshipEnded` on the other side
public extension Store {
    enum HandshakeError: Error, Equatable {
        case notSignedIn
        case ownInvite
        case blocked
        case alreadyFriends
        case unknownRequest
        case unknownLink
    }

    /// B side. Creates (or reuses) a pending link for this invite.
    func beginFriendRequest(_ invite: FriendInvitePayload) throws -> FriendLink {
        guard let me = userID else { throw HandshakeError.notSignedIn }
        if my.invites[invite.t] != nil || invite.u == me { throw HandshakeError.ownInvite }
        if let uid = invite.u {
            if isBlocked(uid) { throw HandshakeError.blocked }
            if let existing = friendLink(for: uid), existing.status == .active { throw HandshakeError.alreadyFriends }
        }
        return addRequestedLink(invite: invite)
    }

    /// B side. The request record exists on the server now.
    func markRequestSent(linkID: UUID, requestID: String, userID: UserID) {
        guard var link = my.friendLinks[linkID] else { return }
        link.requestID = requestID
        link.userID = userID
        if var p = link.person { p.id = userID; link.person = p }
        upsertFriendLink(link)
    }

    /// A side. Turns a request into a link that waits for the friendship record.
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
        var link = friendLink(for: uid) ?? FriendLink(userID: uid, person: req.person, status: .awaitingTheirShare, createdAt: now, updatedAt: now)
        link.person = req.person
        link.requestID = requestID
        link.status = .awaitingTheirShare
        upsertFriendLink(link)
        dismissRequest(requestID)
        return my.friendLinks[link.id] ?? link
    }

    /// Both sides: the friendship record arrived. Idempotent.
    func friendshipConfirmed(with uid: UserID, person: PersonRef?) {
        guard uid != userID, !isBlocked(uid) else { return }
        let now = clock()
        var link = friendLink(for: uid) ?? FriendLink(userID: uid, person: person, status: .active, createdAt: now, updatedAt: now)
        if let person { link.person = person }
        link.userID = uid
        link.status = .active
        link.requestID = nil
        link.inviteToken = nil
        upsertFriendLink(link)
        mutateMy { m in for (k, v) in m.requests where v.person.id == uid { m.requests[k] = nil } }
    }

    /// The friendship record is gone (they unfriended or blocked me, or I did on another device).
    func friendshipEnded(with uid: UserID) {
        guard let link = friendLink(for: uid), link.status == .active else {
            mutateCache { $0.friends[uid] = nil }
            return
        }
        removeFriendLocal(link.id)
    }

    /// Cancel a request I sent (B side) or a pending acceptance (A side).
    func cancelPendingLink(_ linkID: UUID) {
        guard let link = my.friendLinks[linkID], link.status != .active else { return }
        removeFriendLocal(link.id)
    }
}
