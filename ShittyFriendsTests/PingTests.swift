import XCTest
@testable import ShittyFriends

final class PingTests: XCTestCase {
    let sealer = FakeSealer()

    /// Turns an outgoing ping into what the recipient would read back from the public database.
    func deliver(_ p: OutgoingPing, now: Date) throws -> IncomingPing {
        IncomingPing(recordName: UUID().uuidString, to: p.to, kind: p.kind, from: p.from, ref: try sealer.seal(p.payload, keyBase64URL: p.key), expiresAt: p.expiresAt, createdAt: now)
    }

    func makePair() -> (TestClock, Store, Store) {
        let clock = TestClock()
        let (a, _) = TestEnv.store(clock: clock, userID: "_alice")
        a.updateProfile(handle: "alice", color: .hotPink)
        let (b, _) = TestEnv.store(clock: clock, userID: "_bob")
        b.updateProfile(handle: "bob", color: .electric)
        return (clock, a, b)
    }

    /// Runs the full three-step handshake, playing the platform's part (share URLs are fake).
    func befriend(_ a: Store, _ b: Store, clock: TestClock) throws {
        let invite = a.friendInvitePayload()
        let (bLink, request) = try b.beginFriendRequest(invite)
        XCTAssertEqual(bLink.status, .requested)

        guard case .friendRequest(let req) = PingPlanner.process(try deliver(request, now: clock.now), store: a, sealer: sealer, now: clock.now) else {
            return XCTFail("A should see a friend request")
        }
        XCTAssertEqual(req.person.id, "_bob")
        XCTAssertEqual(req.person.handle, "bob")
        XCTAssertTrue(a.receiveFriendRequest(req))

        let aLink = try a.acceptFriendRequest(req.id)
        XCTAssertEqual(aLink.status, .awaitingTheirShare)
        XCTAssertTrue(a.friendRequests.isEmpty)
        let accept = try XCTUnwrap(PingPlanner.friendAccept(link: aLink, shareURL: "https://www.icloud.com/share/alice", store: a, now: clock.now))

        guard case .friendAccepted(let linkID, let person, let theirInbox, let url) = PingPlanner.process(try deliver(accept, now: clock.now), store: b, sealer: sealer, now: clock.now) else {
            return XCTFail("B should see the accept")
        }
        XCTAssertEqual(linkID, bLink.id)
        XCTAssertEqual(person.id, "_alice")
        XCTAssertEqual(url, "https://www.icloud.com/share/alice")
        XCTAssertEqual(theirInbox, aLink.myInbox)
        try b.completeAsRequester(linkID: linkID, person: person, theirInbox: theirInbox, shareURL: url)
        let bActive = try XCTUnwrap(b.my.friendLinks[linkID])
        XCTAssertEqual(bActive.status, .active)
        let complete = try XCTUnwrap(PingPlanner.friendComplete(link: bActive, shareURL: "https://www.icloud.com/share/bob", store: b, now: clock.now))

        guard case .friendCompleted(let aLinkID, let bURL) = PingPlanner.process(try deliver(complete, now: clock.now), store: a, sealer: sealer, now: clock.now) else {
            return XCTFail("A should see the completion")
        }
        XCTAssertEqual(aLinkID, aLink.id)
        try a.completeAsAccepter(linkID: aLinkID, shareURL: bURL)
        XCTAssertTrue(a.isFriend("_bob"))
        XCTAssertTrue(b.isFriend("_alice"))
    }

    func testFullHandshake() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        // Both sides earned the friend achievement.
        XCTAssertNotNil(a.my.achievements[.firstFriend])
        XCTAssertNotNil(b.my.achievements[.firstFriend])
    }

    func testCannotAnswerOwnInvite() {
        let (_, a, _) = makePair()
        let invite = a.friendInvitePayload()
        XCTAssertThrowsError(try a.beginFriendRequest(invite)) { XCTAssertEqual($0 as? Store.HandshakeError, .ownInvite) }
    }

    func testForgedAcceptWithWrongKeyIsIgnored() throws {
        let (clock, a, b) = makePair()
        let invite = a.friendInvitePayload()
        let (bLink, _) = try b.beginFriendRequest(invite)
        var forged = PingPayload(uid: "_mallory", handle: "mallory", inbox: "x", shareURL: "https://evil")
        forged.at = clock.now
        let ping = IncomingPing(recordName: "r", to: bLink.myInbox, kind: .friendAccept, from: nil, ref: try sealer.seal(forged, keyBase64URL: "wrong-key-wrong-key"), expiresAt: clock.now.addingTimeInterval(60), createdAt: clock.now)
        if case .friendAccepted = PingPlanner.process(ping, store: b, sealer: sealer, now: clock.now) {
            XCTFail("a ping sealed with the wrong key must not be accepted")
        }
    }

    func testExpiredAndRevokedInvites() throws {
        let (clock, a, b) = makePair()
        let invite = a.friendInvitePayload()
        let (_, request) = try b.beginFriendRequest(invite)
        let incoming = try deliver(request, now: clock.now)
        a.revokeInvites()
        if case .friendRequest = PingPlanner.process(incoming, store: a, sealer: sealer, now: clock.now) {
            XCTFail("revoked invite must not produce requests")
        }
        clock.advance(8 * 24 * 3600)
        if case .friendRequest = PingPlanner.process(incoming, store: a, sealer: sealer, now: clock.now) {
            XCTFail("expired ping must be ignored")
        }
    }

    func testPoopPingsGoToFriendsAndNonFriendGroupMembersOnce() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        // A owns a group with B (a friend) and Josh (not a friend).
        let g = try XCTUnwrap(a.createGroupLocal(name: "The Boys", object: .crown, color: .sun))
        let josh = PersonRef(id: "_josh", handle: "josh", avatar: AvatarSpec(), color: .mint)
        let bob = PersonRef(id: "_bob", handle: "bob", avatar: AvatarSpec(), color: .electric)
        a.apply([
            .upsert(.member(GroupMember(person: josh, inbox: "josh-in", role: .member)), zone: g.zone),
            .upsert(.member(GroupMember(person: bob, inbox: "bob-group-in", role: .member)), zone: g.zone)
        ])
        let e = a.logInstant()
        let pings = PingPlanner.pings(for: .poop(eventID: e.id, kind: .poopInstant), store: a, now: clock.now)
        let bobFriendInbox = try XCTUnwrap(a.friendLink(for: "_bob")?.theirInbox)
        XCTAssertEqual(Set(pings.map { $0.to }), [bobFriendInbox, "josh-in"])
        let groupPing = try XCTUnwrap(pings.first { $0.to == "josh-in" })
        XCTAssertEqual(groupPing.from, g.myInbox)
        XCTAssertEqual(groupPing.payload.groupID, g.id.uuidString)
        XCTAssertEqual(groupPing.eventID, e.id)

        // Manual logs never ping.
        let manual = a.addManual(at: clock.now.addingTimeInterval(-3600), duration: nil, location: nil)
        XCTAssertTrue(PingPlanner.pings(for: .poop(eventID: manual.id, kind: .poopInstant), store: a, now: clock.now).isEmpty)
    }

    func testSubscriptionsFollowPreferences() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        let link = try XCTUnwrap(a.friendLink(for: "_bob"))
        var kinds = PingPlanner.alertKinds(store: a, now: clock.now)
        XCTAssertEqual(kinds[link.myInbox], Set(PingKind.poopKinds + PingKind.pwmKinds + PingKind.partyKinds))

        a.setFriendNotify(link.id, .pwmOnly)
        kinds = PingPlanner.alertKinds(store: a, now: clock.now)
        XCTAssertEqual(kinds[link.myInbox], Set(PingKind.pwmKinds + PingKind.partyKinds))

        a.setFriendNotify(link.id, .off)
        kinds = PingPlanner.alertKinds(store: a, now: clock.now)
        XCTAssertNil(kinds[link.myInbox])

        a.setFriendNotify(link.id, .every)
        a.updateSettings { $0.notifyFriendPoops = false }
        kinds = PingPlanner.alertKinds(store: a, now: clock.now)
        XCTAssertEqual(kinds[link.myInbox], Set(PingKind.pwmKinds + PingKind.partyKinds))

        // Open invites listen for requests.
        let invite = a.currentInvite()
        kinds = PingPlanner.alertKinds(store: a, now: clock.now)
        XCTAssertEqual(kinds[invite.token], [.friendRequest])
    }

    func testSubscriptionChunkingIsStable() {
        let clock = TestClock()
        let (s, _) = TestEnv.store(clock: clock)
        for i in 0..<65 {
            let link = FriendLink(userID: "_u\(i)", person: PersonRef(id: "_u\(i)", handle: "u\(i)", avatar: AvatarSpec(), color: .aqua), status: .active, myInbox: String(format: "tok%03d", i), theirInbox: "t\(i)", pairKey: "k")
            s.upsertFriendLink(link)
        }
        let specs = PingPlanner.subscriptionSpecs(store: s, now: clock.now)
        XCTAssertEqual(specs.count, 3)
        XCTAssertEqual(specs.flatMap { $0.tokens }.count, 65)
        XCTAssertTrue(specs.allSatisfy { $0.tokens.count <= PingPlanner.tokensPerSubscription })
        XCTAssertEqual(specs, PingPlanner.subscriptionSpecs(store: s, now: clock.now))
        XCTAssertTrue(specs.allSatisfy { $0.id.hasPrefix(SubscriptionSpec.idPrefix) })
    }

    func testDirectoryResolvesFriendsGroupsAndInvites() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        let g = try XCTUnwrap(a.createGroupLocal(name: "Dorm", object: .roll, color: .aqua))
        a.apply([.upsert(.member(GroupMember(person: PersonRef(id: "_josh", handle: "josh", avatar: AvatarSpec(), color: .mint), inbox: "josh-in", role: .member)), zone: g.zone)])
        let invite = a.currentInvite()
        let d = PingPlanner.directory(store: a, now: clock.now)
        let link = try XCTUnwrap(a.friendLink(for: "_bob"))
        XCTAssertEqual(d.entries[link.myInbox]?.title, "bob")
        XCTAssertEqual(d.entries[link.myInbox]?.key, link.pairKey)
        XCTAssertEqual(d.entries[g.myInbox]?.title, "Dorm")
        XCTAssertEqual(d.entries[g.myInbox]?.members["josh-in"], "@josh")
        XCTAssertEqual(d.entries[invite.token]?.kind, .invite)
        // The NSE can produce a real line for a group ping.
        let text = NotificationTextBuilder.text(kind: .poopStart, entry: d.entries[g.myInbox], senderToken: "josh-in", payload: nil, privateMode: false, quiet: false)
        XCTAssertEqual(text.title, "💩 @josh is pooping")
        XCTAssertEqual(text.body, "in Dorm")
    }

    func testPWMInviteRoutesThroughGroupOrFriend() throws {
        let (clock, a, b) = makePair()
        try befriend(a, b, clock: clock)
        let bInbox = try XCTUnwrap(a.friendLink(for: "_bob")?.theirInbox)
        // Ad-hoc space between friends.
        let zone = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session(UUID()))
        a.registerSpace(SpaceLink(zone: zone, kind: .pwm, isOwner: true, shareURL: "https://www.icloud.com/share/space", participantIDs: ["_bob"], expiresAt: clock.now.addingTimeInterval(3600)))
        a.startTimed()
        let bob = try XCTUnwrap(a.person(for: "_bob"))
        let sid = try XCTUnwrap(a.createPWMSession(zone: zone, groupID: nil, invitees: [bob]))
        let pings = PingPlanner.pings(for: .pwmInvite(zone: zone, sessionID: sid, invitees: ["_bob"]), store: a, now: clock.now)
        XCTAssertEqual(pings.count, 1)
        XCTAssertEqual(pings.first?.to, bInbox)
        XCTAssertEqual(pings.first?.payload.shareURL, "https://www.icloud.com/share/space")

        // Bob decodes it.
        let action = PingPlanner.process(try deliver(pings[0], now: clock.now), store: b, sealer: sealer, now: clock.now)
        XCTAssertEqual(action, .pwmInvite(sessionID: sid, groupID: nil, shareURL: "https://www.icloud.com/share/space"))
    }
}
