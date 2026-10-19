import XCTest
@testable import ShittyFriends

final class SocialTests: XCTestCase {
    let josh = PersonRef(id: "_josh", handle: "josh", avatar: AvatarSpec(), color: .hotPink)
    let sam = PersonRef(id: "_sam", handle: "sam", avatar: AvatarSpec(), color: .electric)

    func testPoopWithMeFlowCreatorSide() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session(UUID()))
        store.registerSpace(SpaceLink(zone: zone, kind: .pwm, isOwner: true, expiresAt: clock.now.addingTimeInterval(86400)))
        XCTAssertNil(store.createPWMSession(zone: zone, groupID: nil, invitees: [josh]), "needs a live session")
        let live = store.startTimed()
        let sid = store.createPWMSession(zone: zone, groupID: nil, invitees: [josh, sam])!
        XCTAssertEqual(store.my.events[live.id]?.pwmSessionID, sid)
        XCTAssertTrue(log.pings.contains(.pwmInvite(zone: zone, sessionID: sid, invitees: ["_josh", "_sam"])))
        let view = store.liveSession(sid)!
        XCTAssertEqual(view.participants.count, 3)
        XCTAssertEqual(view.participants.first { $0.id == "_me" }?.status, .joined)

        // Josh joins (arrives from CloudKit)
        clock.advance(60)
        var p = store.cache.zones[zone]!.participants[sid]!["_josh"]!
        p.status = .joined
        p.startedAt = clock.now
        p.updatedAt = clock.now
        store.apply([.upsert(.participant(p), zone: zone)])
        XCTAssertTrue(store.my.confirmedSocialSessions.contains(sid))

        // I finish first; session stays open while Josh is still going.
        clock.advance(120)
        store.finish()
        XCTAssertEqual(store.liveSession(sid)?.session.state, .open)
        XCTAssertEqual(store.cache.zones[zone]!.participants[sid]!["_me"]?.status, .done)

        // Josh finishes -> last one out closes the session.
        p.status = .done
        p.endedAt = clock.now
        p.updatedAt = clock.now.addingTimeInterval(1)
        store.apply([.upsert(.participant(p), zone: zone)])
        // A remote update alone doesn't end the session record; the next local check does.
        _ = store.maybeEndSession(zone: zone, sessionID: sid)
        XCTAssertEqual(store.cache.zones[zone]!.sessions[sid]?.state, .ended)
        XCTAssertNotNil(store.my.pwmArchive[sid])
    }

    func testJoinCountsPlusOneImmediately() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_lee2", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        XCTAssertEqual(store.todayCount(), 0)
        let e = store.joinPWM(zone: zone, sessionID: sid)!
        XCTAssertEqual(store.todayCount(), 1)
        XCTAssertTrue(e.isLive)
        XCTAssertEqual(e.pwmSessionID, sid)
        XCTAssertEqual(store.cache.zones[zone]?.participants[sid]?["_me"]?.status, .joined)
        XCTAssertTrue(log.pings.contains(.pwmJoin(zone: zone, sessionID: sid)))
    }

    func testUndoingAJoinMarksDeclined() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_lee2", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        store.joinPWM(zone: zone, sessionID: sid)
        store.performUndo()
        XCTAssertEqual(store.todayCount(), 0)
        XCTAssertEqual(store.cache.zones[zone]?.participants[sid]?["_me"]?.status, .declined)
    }

    func testPartyLifecycle() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .crown, color: .sun)!
        let at = clock.now.addingTimeInterval(3600)
        let pid = store.createParty(zone: link.zone, groupID: link.id, title: "Friday Flush", at: at, invitees: [josh, sam])!
        XCTAssertTrue(log.contains(.scheduleParty(zone: link.zone, partyID: pid)))
        let view = store.party(pid)!
        XCTAssertEqual(view.rsvps.count, 3)
        XCTAssertEqual(store.myRSVP(view)?.response, .yes)
        XCTAssertFalse(view.party.isJoinable(now: clock.now))
        clock.advance(3600 - 120)
        XCTAssertTrue(store.party(pid)!.party.isJoinable(now: clock.now))
        let e = store.joinParty(zone: link.zone, partyID: pid)!
        XCTAssertEqual(e.partyID, pid)
        XCTAssertEqual(store.todayCount(), 1)
        XCTAssertNotNil(store.myRSVP(store.party(pid)!)?.joinedAt)
    }

    func testFriendRequestDedupAndBlock() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let req = IncomingFriendRequest(id: "p1", inviteToken: "t", person: sam, receivedAt: clock.now)
        XCTAssertTrue(store.receiveFriendRequest(req))
        var req2 = req
        req2.id = "p2"
        XCTAssertTrue(store.receiveFriendRequest(req2))
        XCTAssertEqual(store.friendRequests.count, 1)
        XCTAssertEqual(store.friendRequests.first?.id, "p2")
        store.block("_sam")
        XCTAssertEqual(store.friendRequests.count, 0)
        XCTAssertFalse(store.receiveFriendRequest(req))
    }

    func testFriendLinkLifecycleAndRemoteZoneGone() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let link = FriendLink(userID: "_sam", person: sam, status: .active)
        store.upsertFriendLink(link)
        XCTAssertEqual(store.activeFriendLinks.count, 1)
        XCTAssertTrue(store.my.achievements[.firstFriend] != nil)

        let samZone = ZoneRef(ownerName: "_sam", zoneName: ZoneNames.me)
        let e = PoopEvent(source: .timed, startedAt: clock.now)
        store.apply([
            .upsert(.profile(UserProfile(handle: "sammy", avatar: AvatarSpec(), color: .electric)), zone: samZone),
            .upsert(.event(e), zone: samZone)
        ])
        let summary = store.friendSummaries().first!
        XCTAssertEqual(summary.person.handle, "sammy")
        XCTAssertEqual(summary.todayCount, 1)
        XCTAssertEqual(summary.live?.id, e.id)
        XCTAssertEqual(store.friendLink(for: "_sam")?.person?.handle, "sammy")

        store.apply([.zoneDeleted(samZone)])
        XCTAssertTrue(store.activeFriendLinks.isEmpty)
        XCTAssertNil(store.cache.friends["_sam"])
        XCTAssertTrue(log.contains(.friendZoneGone("_sam")))
    }

    func testRemoteDoesNotClobberNewerLocal() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(10)
        store.tapPoop()
        var stale = e
        stale.updatedAt = e.updatedAt.addingTimeInterval(-100)
        store.apply([.upsert(.event(stale), zone: .me)])
        XCTAssertEqual(store.my.events[e.id]?.taps, 1)
    }

    func testDuplicateHandleLabels() {
        let t0 = Date(timeIntervalSince1970: 0)
        let labels = HandleRules.groupLabels([
            ("_a", "lee", t0.addingTimeInterval(10)),
            ("_b", "Lee", t0),
            ("_c", "sam", t0)
        ])
        XCTAssertEqual(labels["_b"], "@lee (1)")
        XCTAssertEqual(labels["_a"], "@lee (2)")
        XCTAssertEqual(labels["_c"], "@sam")
        let after = HandleRules.groupLabels([("_a", "leew", t0), ("_b", "lee", t0), ("_c", "sam", t0)])
        XCTAssertEqual(after["_a"], "@leew")
        XCTAssertEqual(after["_b"], "@lee")
    }

    func testGroupJoinDoesNotExposeOlderHistoryAndLeaderboard() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        store.logInstant()
        clock.advance(60)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.group(UUID()))
        let gid = ZoneNames.groupID(fromZoneName: zone.zoneName)!
        log.effects.removeAll()
        store.registerGroupRequest(groupID: gid, ownerID: "_josh", name: "Class", object: .toilet, color: .violet)
        XCTAssertEqual(store.my.groupLinks[gid]?.status, .requested)
        XCTAssertTrue(store.groupSummaries.isEmpty, "not a member until the owner approves")
        // While waiting, nothing of mine is mirrored.
        store.logInstant()
        XCTAssertNil(store.cache.zones[zone]?.events.values.first)
        // The owner approved: my member row arrives (the server's joinedAt is after that poop).
        clock.advance(1)
        store.apply([.upsert(.member(GroupMember(person: store.meRef, role: .member, joinedAt: clock.now)), zone: zone)])
        XCTAssertEqual(store.my.groupLinks[gid]?.status, .active)
        XCTAssertTrue(log.saves.filter { if case .groupEvent = $0 { return true } else { return false } }.isEmpty,
                      "group membership is not personal-history access: nothing before joining is mirrored")
        XCTAssertEqual(store.my.groupLinks[gid]?.notify, .pwmAndParties, "joining by link starts quiet: no alert per member poop")
        clock.advance(60)
        store.logInstant()
        clock.advance(60)
        store.logInstant()
        XCTAssertEqual(store.cache.zones[zone]?.events.count, 2)
        store.apply([.upsert(.member(GroupMember(person: josh, role: .owner, joinedAt: clock.now.addingTimeInterval(-999))), zone: zone)])
        let board = store.leaderboard(zone)
        XCTAssertEqual(board.first?.member.id, "_me")
        XCTAssertEqual(board.first?.count, 2)
        XCTAssertEqual(board.last?.count, 0)
    }

    func testLeavingGroupCleansUpMyRecords() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.group(UUID()))
        let gid = ZoneNames.groupID(fromZoneName: zone.zoneName)!
        store.registerGroupRequest(groupID: gid, ownerID: "_josh", name: "Class", object: .toilet, color: .violet)
        store.apply([.upsert(.member(GroupMember(person: store.meRef, role: .member, joinedAt: clock.now)), zone: zone)])
        let e = store.logInstant()
        log.effects.removeAll()
        store.removeGroupLocal(gid)
        XCTAssertTrue(log.deletes.contains(.groupEvent(zone, e.id)))
        XCTAssertTrue(log.deletes.contains(.member(zone, "_me")))
        XCTAssertNil(store.cache.zones[zone])
        XCTAssertTrue(store.groupSummaries.isEmpty)
    }

    func testInviteReuse() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let a = store.currentInvite()
        let b = store.currentInvite()
        XCTAssertEqual(a.token, b.token)
        clock.advance(6.5 * 24 * 3600)
        let c = store.currentInvite()
        XCTAssertNotEqual(a.token, c.token, "less than a day left -> new invite")
        clock.advance(2 * 24 * 3600)
        _ = store.currentInvite()
        XCTAssertNil(store.my.invites[a.token], "expired invites get dropped")
    }
}
