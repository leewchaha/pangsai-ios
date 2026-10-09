import XCTest
@testable import ShittyFriends

/// The friend handshake on top of the server's request / friendship records, as the store sees it.
/// (The platform writes the records; here the "server" is played by hand.)
final class HandshakeTests: XCTestCase {
    func makePair() -> (TestClock, Store, Store) {
        let clock = TestClock()
        let (a, _) = TestEnv.store(clock: clock, userID: "_alice")
        a.updateProfile(handle: "alice", color: .hotPink)
        let (b, _) = TestEnv.store(clock: clock, userID: "_bob")
        b.updateProfile(handle: "bob", color: .electric)
        return (clock, a, b)
    }

    /// Runs the full handshake, playing the platform's part.
    func befriend(_ a: Store, _ b: Store, clock: TestClock) throws {
        let invite = a.friendInvitePayload()
        XCTAssertEqual(invite.u, "_alice", "v2 links carry the inviter's id")
        let bLink = try b.beginFriendRequest(invite)
        XCTAssertEqual(bLink.status, .requested)
        XCTAssertEqual(bLink.userID, "_alice")
        b.markRequestSent(linkID: bLink.id, requestID: "req-1", userID: "_alice")
        XCTAssertEqual(b.my.friendLinks[bLink.id]?.requestID, "req-1")

        // The request record reaches A.
        XCTAssertTrue(a.receiveFriendRequest(IncomingFriendRequest(id: "req-1", inviteToken: invite.t, person: b.meRef, receivedAt: clock.now)))
        XCTAssertEqual(a.friendRequests.first?.person.handle, "bob")
        let aLink = try a.acceptFriendRequest("req-1")
        XCTAssertEqual(aLink.status, .awaitingTheirShare)
        XCTAssertTrue(a.friendRequests.isEmpty)

        // The friendship record comes back to both.
        a.friendshipConfirmed(with: "_bob", person: b.meRef)
        b.friendshipConfirmed(with: "_alice", person: a.meRef)
        XCTAssertTrue(a.isFriend("_bob"))
        XCTAssertTrue(b.isFriend("_alice"))
        XCTAssertNil(b.my.friendLinks[bLink.id]?.requestID, "a finished handshake keeps no request id")
    }

    func testFullHandshake() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        XCTAssertNotNil(a.my.achievements[.firstFriend])
        XCTAssertNotNil(b.my.achievements[.firstFriend])
        XCTAssertEqual(a.activeFriendLinks.count, 1)
        XCTAssertEqual(b.activeFriendLinks.count, 1)
    }

    func testCannotAnswerOwnInvite() {
        let (_, a, _) = makePair()
        let invite = a.friendInvitePayload()
        XCTAssertThrowsError(try a.beginFriendRequest(invite)) { XCTAssertEqual($0 as? Store.HandshakeError, .ownInvite) }
    }

    func testAlreadyFriendsIsRefused() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        XCTAssertThrowsError(try b.beginFriendRequest(a.friendInvitePayload())) { XCTAssertEqual($0 as? Store.HandshakeError, .alreadyFriends) }
    }

    func testDeclinedRequestIsCleanedUp() throws {
        let (_, a, b) = makePair()
        let link = try b.beginFriendRequest(a.friendInvitePayload())
        b.markRequestSent(linkID: link.id, requestID: "req-9", userID: "_alice")
        XCTAssertEqual(b.pendingFriendLinks.count, 1)
        // The platform saw the request record disappear without a friendship.
        b.cancelPendingLink(link.id)
        XCTAssertTrue(b.pendingFriendLinks.isEmpty)
        XCTAssertNil(b.friendLink(for: "_alice"))
    }

    func testUnfriendEndsBothSides() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        let samZone = ZoneRef(ownerName: "_alice", zoneName: ZoneNames.me)
        b.apply([.upsert(.event(PoopEvent(source: .instant, startedAt: clock.now)), zone: samZone)])
        XCTAssertEqual(b.friendEvents("_alice").count, 1)
        // A unfriends: A's side locally, B's side when the friendship record vanishes.
        let aLink = try XCTUnwrap(a.friendLink(for: "_bob"))
        a.removeFriendLocal(aLink.id)
        XCTAssertFalse(a.isFriend("_bob"))
        b.friendshipEnded(with: "_alice")
        XCTAssertFalse(b.isFriend("_alice"))
        XCTAssertTrue(b.friendEvents("_alice").isEmpty, "their history is purged")
    }

    func testFriendshipConfirmedIsIdempotentAndKeepsPrefs() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        let link = try XCTUnwrap(a.friendLink(for: "_bob"))
        a.setFriendNotify(link.id, .pwmOnly)
        a.friendshipConfirmed(with: "_bob", person: b.meRef)
        XCTAssertEqual(a.activeFriendLinks.count, 1)
        XCTAssertEqual(a.friendLink(for: "_bob")?.notify, .pwmOnly)
    }

    func testInviteReuseAndExpiry() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let a = store.currentInvite()
        XCTAssertTrue(log.saves.contains(.invite(a.token)))
        let b = store.currentInvite()
        XCTAssertEqual(a.token, b.token)
        clock.advance(6.5 * 24 * 3600)
        let c = store.currentInvite()
        XCTAssertNotEqual(a.token, c.token, "less than a day left -> new invite")
        clock.advance(2 * 24 * 3600)
        _ = store.currentInvite()
        XCTAssertNil(store.my.invites[a.token], "expired invites get dropped")
        XCTAssertTrue(log.deletes.contains(.invite(a.token)))
    }

    func testGroupJoinRequestsForTheOwner() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .crown, color: .sun)!
        XCTAssertTrue(log.contains(.ensureZone(link.zone)))
        XCTAssertFalse(store.cache.zones[link.zone]!.group!.inviteCode.isEmpty)
        let sam = PersonRef(id: "_sam", handle: "sam", avatar: AvatarSpec(), color: .electric)
        store.apply([.upsert(.joinRequest(GroupJoinRequest(person: sam, createdAt: clock.now)), zone: link.zone)])
        XCTAssertEqual(store.joinRequests(link.id).map(\.id), ["_sam"])
        XCTAssertEqual(store.person(for: "_sam")?.handle, "sam")
        // Approve: the request leaves the list at once; the member row arrives from the server.
        XCTAssertNotNil(store.settleJoinRequest(link.id, member: "_sam"))
        XCTAssertTrue(store.joinRequests(link.id).isEmpty)
        store.apply([.upsert(.member(GroupMember(person: sam, role: .member, joinedAt: clock.now)), zone: link.zone)])
        XCTAssertEqual(store.group(link.id)?.members.count, 2)
        XCTAssertNil(store.settleJoinRequest(link.id, member: "_nobody"))
    }

    func testDeclinedGroupRequestDisappears() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let gid = UUID()
        store.registerGroupRequest(groupID: gid, ownerID: "_josh", name: "Class", object: .toilet, color: .violet)
        XCTAssertEqual(store.pendingGroupLinks.count, 1)
        log.effects.removeAll()
        store.groupRequestEnded(gid)
        XCTAssertTrue(store.pendingGroupLinks.isEmpty)
        XCTAssertTrue(log.deletes.contains(.groupLink(gid)))
        // Ending a request that was already approved does nothing.
        store.registerGroupRequest(groupID: gid, ownerID: "_josh", name: "Class", object: .toilet, color: .violet)
        store.groupApproved(gid, joinedAt: clock.now)
        store.groupRequestEnded(gid)
        XCTAssertEqual(store.my.groupLinks[gid]?.status, .active)
    }
}
