import XCTest
@testable import ShittyFriends

/// 2026-10-09 decisions: only live-logged poops compete; no solo parties; International Incident
/// takes two members; Poop With Me never times out while someone is still in it; a blocked person
/// can't come back as a friend through any path; JOIN from a notification checks its target.
final class CountingRulesTests: XCTestCase {
    let josh = PersonRef(id: "_josh", handle: "josh", avatar: AvatarSpec(), color: .hotPink)
    let sam = PersonRef(id: "_sam", handle: "sam", avatar: AvatarSpec(), color: .electric)

    // MARK: - What counts

    func testManualEditedAndImportedPoopsStayOutOfRankings() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .crown, color: .sun)!
        let live = store.logInstant()
        clock.advance(60)
        let manual = store.addManual(at: clock.now.addingTimeInterval(-600), duration: nil, location: nil)
        clock.advance(60)
        let edited = store.logInstant()
        store.edit(edited.id, start: clock.now.addingTimeInterval(-3600))
        clock.advance(60)
        let imported = PoopEvent(source: .instant, startedAt: clock.now.addingTimeInterval(-120))
        store.importHistory([imported])

        XCTAssertTrue(store.my.events[live.id]!.countsForRanking)
        XCTAssertFalse(store.my.events[manual.id]!.countsForRanking)
        XCTAssertFalse(store.my.events[edited.id]!.countsForRanking)
        XCTAssertTrue(store.my.events[imported.id]!.imported)
        XCTAssertFalse(store.my.events[imported.id]!.countsForRanking)

        // Personal stats and history keep everything.
        XCTAssertEqual(store.stats().total, 4)
        XCTAssertEqual(store.todayCount(), 4)
        XCTAssertEqual(store.myHighlightCards(period: .day).first { $0.kind == .total }?.headline, "4")
        // Rankings see one.
        XCTAssertEqual(store.friendLeaderboard().first?.count, 1)
        XCTAssertEqual(store.leaderboard(link.zone).first { $0.member.id == "_me" }?.count, 1)
        XCTAssertEqual(store.groupHighlightParticipants(link.zone).first?.events.count, 1)
        XCTAssertEqual(store.friendHighlightParticipants().first?.events.count, 1)
        // The group copy carries the flags so every member applies the same rule.
        XCTAssertTrue(store.cache.zones[link.zone]?.events[edited.id]?.manuallyAdjusted ?? false)
    }

    func testAchievementsOnlySeeLivePoops() {
        let clock = TestClock("2026-10-06T02:30:00+09:00")
        let (store, _) = TestEnv.store(clock: clock)
        // A night-shift log added later earns nothing...
        store.addManual(at: clock.now, duration: nil, location: nil)
        XCTAssertNil(store.my.achievements[.nightShift])
        XCTAssertNil(store.my.achievements[.firstDrop])
        // ...a live one does.
        store.logInstant()
        XCTAssertNotNil(store.my.achievements[.nightShift])
        XCTAssertNotNil(store.my.achievements[.firstDrop])
    }

    func testRenamingThePlaceOrEndingATimerIsNotACorrection() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        store.attachLocation(PoopLocation(latitude: 36.7, longitude: 137.2, placeName: "Home"), to: e.id)
        clock.advance(300)
        // Ending a running timer from the editor = DONE, not a correction.
        store.edit(e.id, end: .some(clock.now))
        XCTAssertFalse(store.my.events[e.id]!.manuallyAdjusted)
        XCTAssertTrue(store.my.events[e.id]!.countsForRanking)
        // Renaming the pin keeps it where it was.
        var renamed = store.my.events[e.id]!.location!
        renamed.placeName = "Throne Room"
        store.edit(e.id, location: .some(renamed))
        XCTAssertFalse(store.my.events[e.id]!.manuallyAdjusted)
        // Group sharing is a visibility setting, not an edit.
        store.edit(e.id, sharedToGroups: false)
        XCTAssertFalse(store.my.events[e.id]!.manuallyAdjusted)
        // Moving the pin is a correction.
        store.edit(e.id, location: .some(PoopLocation(latitude: 35.0, longitude: 135.0, placeName: "Kyoto")))
        XCTAssertTrue(store.my.events[e.id]!.manuallyAdjusted)
        XCTAssertFalse(store.my.events[e.id]!.countsForRanking)
    }

    func testFixingAFinishedTimerDurationIsACorrection() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(300)
        store.finish()
        store.edit(e.id, end: .some(e.startedAt.addingTimeInterval(60)))
        XCTAssertTrue(store.my.events[e.id]!.manuallyAdjusted)
    }

    func testOldRecordsWithoutTheNewFlagsStillDecode() throws {
        let e = PoopEvent(source: .instant, startedAt: Date(timeIntervalSince1970: 1_000_000))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        json.removeValue(forKey: "imported")
        let old = try JSONDecoder().decode(PoopEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.imported)
        XCTAssertTrue(old.countsForRanking)

        let g = GroupEvent(event: e, ownerID: "_me", includeLocation: false)
        var gj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as? [String: Any])
        gj.removeValue(forKey: "imported")
        gj.removeValue(forKey: "manuallyAdjusted")
        let oldG = try JSONDecoder().decode(GroupEvent.self, from: JSONSerialization.data(withJSONObject: gj))
        XCTAssertTrue(oldG.countsForRanking)

        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        settings.removeValue(forKey: "blockedHandles")
        settings.removeValue(forKey: "longSessionReminder")
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: settings))
        XCTAssertTrue(oldSettings.longSessionReminder)
        XCTAssertTrue(oldSettings.blockedHandles.isEmpty)
    }

    // MARK: - Parties

    func testASoloPartyEarnsNothing() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "Just Me", object: .crown, color: .sun)!
        for i in 0..<4 {
            let at = clock.now.addingTimeInterval(60)
            let pid = store.createParty(zone: link.zone, groupID: link.id, title: "Solo \(i)", at: at, invitees: [])!
            clock.advance(60)
            store.joinParty(zone: link.zone, partyID: pid)
            clock.advance(120)
            store.finish()
            clock.advance(3600 * 2)
        }
        XCTAssertNil(store.my.achievements[.partyAnimal])
        XCTAssertNil(store.my.achievements[.perfectAttendance])
        XCTAssertEqual(store.achievementProgress(.partyAnimal)?.current, 0)
    }

    func testPartiesWithSomebodyElseCount() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .crown, color: .sun)!
        for i in 0..<3 {
            let at = clock.now.addingTimeInterval(60)
            let pid = store.createParty(zone: link.zone, groupID: link.id, title: "Party \(i)", at: at, invitees: [josh])!
            clock.advance(60)
            store.joinParty(zone: link.zone, partyID: pid)
            // Josh turns up (arrives from sync).
            var r = store.cache.zones[link.zone]!.rsvps[pid]!["_josh"]!
            r.response = .yes
            r.joinedAt = clock.now
            r.updatedAt = clock.now
            store.apply([.upsert(.rsvp(r), zone: link.zone)])
            XCTAssertTrue(store.my.confirmedSocialParties.contains(pid))
            clock.advance(120)
            store.finish()
            clock.advance(3600 * 2)
        }
        XCTAssertNotNil(store.my.achievements[.partyAnimal])
        XCTAssertNotNil(store.my.achievements[.perfectAttendance])
    }

    func testCanJoinPartyChecks() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .crown, color: .sun)!
        let pid = store.createParty(zone: link.zone, groupID: link.id, title: "Later", at: clock.now.addingTimeInterval(3600), invitees: [josh])!
        XCTAssertFalse(store.canJoinParty(pid), "not open yet")
        clock.advance(3600)
        XCTAssertTrue(store.canJoinParty(pid))
        store.joinParty(zone: link.zone, partyID: pid)
        XCTAssertFalse(store.canJoinParty(pid), "already in")
        store.finish()
        clock.advance(2 * 3600)
        XCTAssertFalse(store.canJoinParty(pid), "over")
        XCTAssertFalse(store.canJoinParty(UUID()), "unknown")
    }

    func testJoinBeforeSyncDetachesWhenThePartyWasOver() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let pid = UUID()
        let e = store.startTimed(partyID: pid)
        XCTAssertEqual(store.todayCount(), 1)
        store.detachFromParty(eventID: e.id)
        XCTAssertNil(store.my.events[e.id]?.partyID)
        XCTAssertEqual(store.todayCount(), 1, "the poop still counts")
        let sid = UUID()
        let f = store.startTimed(pwmSessionID: sid)
        XCTAssertEqual(f.id, e.id, "already live: attached, not a second poop")
        store.detachFromPWM(eventID: e.id)
        XCTAssertNil(store.my.events[e.id]?.pwmSessionID)
    }

    // MARK: - Poop With Me

    func testSessionStaysLiveWhileSomeoneIsStillInIt() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        store.apply([
            .upsert(.pwmSession(PWMSession(id: sid, creatorID: "_josh", createdAt: clock.now)), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: josh, status: .joined, startedAt: clock.now)), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: store.meRef, status: .invited)), zone: zone)
        ])
        clock.advance(5 * 3600)
        XCTAssertNotNil(store.liveSession(sid), "no cutoff while Josh is still pooping")
        XCTAssertEqual(store.pendingInvites().count, 1)
        XCTAssertTrue(store.canJoinPWM(sid))
        // Josh finishes: the stale invite ages out.
        store.apply([.upsert(.participant(PWMParticipant(sessionID: sid, person: josh, status: .done, startedAt: clock.now.addingTimeInterval(-5 * 3600), endedAt: clock.now, updatedAt: clock.now)), zone: zone)])
        XCTAssertNil(store.liveSession(sid))
    }

    func testCanJoinPWMIsFalseWhileAlreadyIn() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        store.apply([
            .upsert(.pwmSession(PWMSession(id: sid, creatorID: "_josh", createdAt: clock.now)), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: josh, status: .joined, startedAt: clock.now)), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: store.meRef, status: .invited)), zone: zone)
        ])
        XCTAssertTrue(store.canJoinPWM(sid))
        store.joinPWM(zone: zone, sessionID: sid)
        XCTAssertFalse(store.canJoinPWM(sid))
        XCTAssertEqual(store.todayCount(), 1)
        store.finish()
        XCTAssertTrue(store.canJoinPWM(sid), "done, but Josh is still going: JOIN again means a new poop")
    }

    // MARK: - Blocking

    func testBlockedPersonCannotComeBackThroughTheHandshakeOrSync() throws {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let link = FriendLink(userID: "_sam", person: sam, status: .active)
        store.upsertFriendLink(link)
        let samZone = ZoneRef(ownerName: "_sam", zoneName: ZoneNames.me)
        store.apply([.upsert(.profile(UserProfile(handle: "sam", avatar: AvatarSpec(), color: .electric)), zone: samZone)])
        XCTAssertEqual(store.activeFriendLinks.count, 1)

        store.block("_sam")
        XCTAssertTrue(store.activeFriendLinks.isEmpty)
        XCTAssertNil(store.cache.friends["_sam"])
        XCTAssertTrue(log.contains(.friendZoneGone("_sam")))
        XCTAssertEqual(store.blockedLabel("_sam"), "@sam")

        // Their shared zone keeps syncing until revoked: never cached again.
        store.apply([.upsert(.event(PoopEvent(source: .instant, startedAt: clock.now)), zone: samZone)])
        XCTAssertNil(store.cache.friends["_sam"])
        // A stale link from another device: dropped and deleted remotely.
        store.apply([.upsert(.friendLink(link), zone: .privateZone)])
        XCTAssertNil(store.friendLink(for: "_sam"))
        XCTAssertTrue(log.deletes.contains(.friendLink(link.id)))
        // Direct re-add paths.
        store.upsertFriendLink(link)
        XCTAssertNil(store.friendLink(for: "_sam"))
        let req = IncomingFriendRequest(id: "p1", inviteToken: "t", person: sam, receivedAt: clock.now)
        XCTAssertFalse(store.receiveFriendRequest(req))

        // B side: an old (v1) invite link without an id turns out to be Sam's; a v2 one is refused outright.
        let pending = store.addRequestedLink(invite: FriendInvitePayload(handle: "sam", color: .electric, avatar: AvatarSpec(), token: "tok", userID: nil))
        store.friendshipConfirmed(with: "_sam", person: sam)
        XCTAssertNil(store.friendLink(for: "_sam"), "a friendship record for a blocked person is ignored")
        store.cancelPendingLink(pending.id)
        XCTAssertThrowsError(try store.beginFriendRequest(FriendInvitePayload(handle: "sam", color: .electric, avatar: AvatarSpec(), token: "tok2", userID: "_sam"))) {
            XCTAssertEqual($0 as? Store.HandshakeError, .blocked)
        }

        store.unblock("_sam")
        store.upsertFriendLink(link)
        XCTAssertEqual(store.activeFriendLinks.count, 1, "unblocking is the only way back")
    }

    func testBlockMadeOnAnotherDeviceDropsTheFriendHere() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        store.upsertFriendLink(FriendLink(userID: "_sam", person: sam, status: .active))
        var remote = store.settings
        remote.blockedUserIDs = ["_sam"]
        remote.updatedAt = clock.now.addingTimeInterval(10)
        store.apply([.upsert(.settings(remote), zone: .privateZone)])
        XCTAssertTrue(store.isBlocked("_sam"))
        XCTAssertNil(store.friendLink(for: "_sam"))
    }

    func testAcceptingABlockedPersonIsRefused() throws {
        let clock = TestClock()
        let (a, _) = TestEnv.store(clock: clock, userID: "_alice")
        a.block("_bob")
        let bob = PersonRef(id: "_bob", handle: "bob", avatar: AvatarSpec(), color: .electric)
        // A request record that slipped through (e.g. sent before the block): never accepted here.
        XCTAssertFalse(a.receiveFriendRequest(IncomingFriendRequest(id: "r1", inviteToken: "t", person: bob, receivedAt: clock.now)))
        a.mutateMyForTests { $0.requests["r1"] = IncomingFriendRequest(id: "r1", inviteToken: "t", person: bob, receivedAt: clock.now) }
        XCTAssertThrowsError(try a.acceptFriendRequest("r1")) { XCTAssertEqual($0 as? Store.HandshakeError, .blocked) }
        XCTAssertTrue(a.friendRequests.isEmpty)
    }

    // MARK: - Group trophies

    func testInternationalIncidentNeedsTwoMembers() {
        let cal = TestEnv.calendar
        let t = TestClock.date("2026-10-06T08:00:00+09:00")
        func ge(_ owner: UserID, _ at: Date, _ country: String) -> GroupEvent {
            GroupEvent(id: UUID(), ownerID: owner, source: .instant, startedAt: at, endedAt: nil, location: PoopLocation(latitude: 0, longitude: 0, countryCode: country), pwmSessionID: nil, partyID: nil)
        }
        func earned(_ events: [GroupEvent]) -> Bool {
            GroupAchievementEngine.evaluate(events: events, members: [], sessionParticipants: [], partyRSVPs: [], calendar: cal).first { $0.id == .internationalIncident }!.earned
        }
        // One member abroad: no incident.
        XCTAssertFalse(earned([ge("_a", t, "JP"), ge("_a", t.addingTimeInterval(86400), "MY")]))
        // Two members, two countries: incident.
        XCTAssertTrue(earned([ge("_a", t, "JP"), ge("_b", t.addingTimeInterval(60), "MY")]))
        // Two members, same country: nothing.
        XCTAssertFalse(earned([ge("_a", t, "JP"), ge("_b", t.addingTimeInterval(60), "JP")]))
        // Manual / edited / imported copies never earn it.
        var manual = ge("_b", t.addingTimeInterval(60), "MY")
        manual.source = .manual
        XCTAssertFalse(earned([ge("_a", t, "JP"), manual]))
        var edited = ge("_b", t.addingTimeInterval(60), "MY")
        edited.manuallyAdjusted = true
        XCTAssertFalse(earned([ge("_a", t, "JP"), edited]))
    }
}
