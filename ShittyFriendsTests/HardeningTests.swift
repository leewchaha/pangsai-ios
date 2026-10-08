import XCTest
@testable import ShittyFriends

/// Integrity rules added after the handoff audit: no fake presence, no imported points,
/// no forged group records, and owner-only group controls.
final class HardeningTests: XCTestCase {
    let josh = PersonRef(id: "_josh", handle: "josh", avatar: AvatarSpec(), color: .hotPink)
    let sam = PersonRef(id: "_sam", handle: "sam", avatar: AvatarSpec(), color: .electric)

    // MARK: - Timers

    func testFinishedTimerCannotBecomeLiveAgain() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(300)
        store.finish()
        XCTAssertNil(store.liveEvent)
        store.edit(e.id, end: .some(nil))
        XCTAssertNil(store.liveEvent, "clearing the end of a finished timer must not fake 'currently pooping'")
        XCTAssertNotNil(store.my.events[e.id]?.endedAt)
    }

    func testForgottenLiveTimerCanStillBeEnded() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(3 * 3600)
        store.edit(e.id, end: .some(e.startedAt.addingTimeInterval(420)))
        XCTAssertNil(store.liveEvent)
        XCTAssertEqual(store.my.events[e.id]?.duration, 420)
    }

    // MARK: - Points

    func testImportNeverBringsPoints() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let forged = PoopEvent(source: .timed, startedAt: clock.now.addingTimeInterval(-86400), endedAt: clock.now.addingTimeInterval(-86000), halfPoints: 1_000_000, taps: 99999)
        let added = store.importHistory([forged])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.pointsBalance, 0)
        XCTAssertEqual(store.my.events[forged.id]?.taps, 0)
    }

    func testParsedHistoryHasNoPoints() throws {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        for _ in 0..<20 { clock.advance(0.3); store.tapPoop() }
        store.finish()
        XCTAssertGreaterThan(store.my.events[e.id]!.halfPoints, 0)
        let files = try ExportBuilder.files(store: store)
        let history = try XCTUnwrap(files.first { $0.name.hasSuffix("poop-history.json") })
        let parsed = try ExportBuilder.parseHistory(history.data)
        XCTAssertEqual(parsed.first?.halfPoints, 0)
    }

    func testMultipleSessionsKeepEarningWithoutDailyCap() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        for _ in 0..<3 {
            store.startTimed()
            for _ in 0..<70 { clock.advance(0.3); store.tapPoop() }
            store.finish()
            clock.advance(60)
        }
        XCTAssertEqual(store.pointsBalance, 210, "every tap of every session pays; no session or daily cap")
    }

    // MARK: - Group write authority

    private func joinedGroup(_ store: Store) -> (ZoneRef, UUID) {
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.group(UUID()))
        let gid = ZoneNames.groupID(fromZoneName: zone.zoneName)!
        store.registerJoinedGroup(zone: zone, groupID: gid, name: "Class", shareURL: nil)
        store.apply([.upsertFrom(.groupInfo(GroupInfo(id: gid, name: "Class", object: .toilet, color: .violet, createdBy: "_josh")), zone: zone, writer: "_josh")])
        return (zone, gid)
    }

    func testOwnerWrittenGroupInfoIsAcceptedButForgedIsNot() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let (zone, gid) = joinedGroup(store)
        XCTAssertEqual(store.cache.zones[zone]?.group?.name, "Class")
        store.apply([.upsertFrom(.groupInfo(GroupInfo(id: gid, name: "Hacked", object: .toilet, color: .violet, createdBy: "_josh")), zone: zone, writer: "_sam")])
        XCTAssertEqual(store.cache.zones[zone]?.group?.name, "Class")
    }

    func testMemberCannotOverwriteSomeoneElsesMemberRecord() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let (zone, _) = joinedGroup(store)
        store.apply([.upsertFrom(.member(GroupMember(person: sam, inbox: "sam-in", role: .member)), zone: zone, writer: "_sam")])
        XCTAssertNotNil(store.cache.zones[zone]?.members["_sam"])

        // Sam rewrites MY member record (e.g. to steal my inbox): rejected, and mine is put back.
        log.effects.removeAll()
        var fake = GroupMember(person: store.meRef, inbox: "sam-in", role: .member)
        fake.person.handle = "loser"
        store.apply([.upsertFrom(.member(fake), zone: zone, writer: "_sam")])
        XCTAssertEqual(store.cache.zones[zone]?.members["_me"]?.person.handle, store.profile.handle)
        XCTAssertTrue(log.saves.contains(.member(zone, "_me")))

        // Sam can't make himself owner either.
        store.apply([.upsertFrom(.member(GroupMember(person: sam, inbox: "sam-in", role: .owner)), zone: zone, writer: "_sam")])
        XCTAssertEqual(store.cache.zones[zone]?.members["_sam"]?.role, .member)
    }

    func testForgedPoopInMyNameIsDeleted() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let (zone, _) = joinedGroup(store)
        log.effects.removeAll()
        let fake = GroupEvent(id: UUID(), ownerID: "_me", source: .instant, startedAt: clock.now, endedAt: nil, location: nil, pwmSessionID: nil, partyID: nil)
        store.apply([.upsertFrom(.groupEvent(fake), zone: zone, writer: "_sam")])
        XCTAssertNil(store.cache.zones[zone]?.events[fake.id])
        XCTAssertTrue(log.deletes.contains(.groupEvent(zone, fake.id)))
        XCTAssertEqual(store.leaderboard(zone).first { $0.member.id == "_me" }?.count, 0)
    }

    func testSessionInvitesAndJoinsFollowTheRules() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let (zone, _) = joinedGroup(store)
        let session = PWMSession(creatorID: "_josh")
        store.apply([.upsertFrom(.pwmSession(session), zone: zone, writer: "_josh")])
        // Josh (creator) invites me: allowed.
        store.apply([.upsertFrom(.participant(PWMParticipant(sessionID: session.id, person: store.meRef, status: .invited)), zone: zone, writer: "_josh")])
        XCTAssertEqual(store.cache.zones[zone]?.participants[session.id]?["_me"]?.status, .invited)
        // Sam claims I joined: not allowed (only I can say I'm pooping).
        store.apply([.upsertFrom(.participant(PWMParticipant(sessionID: session.id, person: store.meRef, status: .joined, startedAt: clock.now)), zone: zone, writer: "_sam")])
        XCTAssertEqual(store.cache.zones[zone]?.participants[session.id]?["_me"]?.status, .invited)
        // Sam can't take over the session.
        store.apply([.upsertFrom(.pwmSession(PWMSession(id: session.id, creatorID: "_sam")), zone: zone, writer: "_sam")])
        XCTAssertEqual(store.cache.zones[zone]?.sessions[session.id]?.creatorID, "_josh")
    }

    func testRemoteUnvalidatedUpsertStillWorks() {
        // Records without writer info (e.g. conflict resolution) keep the old path.
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let (zone, _) = joinedGroup(store)
        store.apply([.upsert(.member(GroupMember(person: sam, inbox: "s", role: .member)), zone: zone)])
        XCTAssertNotNil(store.cache.zones[zone]?.members["_sam"])
    }

    // MARK: - Repair and owner controls

    func testRepairPutsBackMyDeletedMemberRecordAndPoops() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let (zone, _) = joinedGroup(store)
        clock.advance(10)
        let e = store.logInstant()
        // Someone deleted my records in the group.
        store.apply([.delete(.member(zone, "_me"), zone: zone), .delete(.groupEvent(zone, e.id), zone: zone)])
        XCTAssertNil(store.cache.zones[zone]?.members["_me"])
        log.effects.removeAll()
        store.repairMyGroupRecords()
        XCTAssertNotNil(store.cache.zones[zone]?.members["_me"])
        XCTAssertNotNil(store.cache.zones[zone]?.events[e.id])
        XCTAssertTrue(log.saves.contains(.member(zone, "_me")))
        XCTAssertTrue(log.saves.contains(.groupEvent(zone, e.id)))
    }

    func testOnlyOwnerCanRemoveMembersOrRename() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let (zone, gid) = joinedGroup(store)
        store.apply([.upsertFrom(.member(GroupMember(person: sam, inbox: "s", role: .member)), zone: zone, writer: "_sam")])
        XCTAssertFalse(store.removeMember(gid, member: "_sam"), "not my group")
        XCTAssertFalse(store.renameGroup(gid, name: "Mine now"))

        let mine = store.createGroupLocal(name: "Boys", object: .toilet, color: .lime)!
        store.apply([.upsertFrom(.member(GroupMember(person: sam, inbox: "s", role: .member)), zone: mine.zone, writer: "_sam")])
        clock.advance(5)
        let ge = GroupEvent(id: UUID(), ownerID: "_sam", source: .instant, startedAt: clock.now, endedAt: nil, location: nil, pwmSessionID: nil, partyID: nil)
        store.apply([.upsertFrom(.groupEvent(ge), zone: mine.zone, writer: "_sam")])
        log.effects.removeAll()
        XCTAssertTrue(store.removeMember(mine.id, member: "_sam"))
        XCTAssertNil(store.cache.zones[mine.zone]?.members["_sam"])
        XCTAssertNil(store.cache.zones[mine.zone]?.events[ge.id])
        XCTAssertTrue(log.deletes.contains(.member(mine.zone, "_sam")))
        XCTAssertFalse(store.removeMember(mine.id, member: "_me"), "can't remove yourself")
    }
}

/// Group trophies, friend ranking, and JOIN-before-sync attachment.
final class GroupFeatureTests: XCTestCase {
    private func ge(_ owner: UserID, _ at: Date, country: String? = nil) -> GroupEvent {
        GroupEvent(id: UUID(), ownerID: owner, source: .instant, startedAt: at, endedAt: nil,
                   location: country.map { PoopLocation(latitude: 0, longitude: 0, countryCode: $0) }, pwmSessionID: nil, partyID: nil)
    }

    private func member(_ id: UserID, joined: Date) -> GroupMember {
        GroupMember(person: PersonRef(id: id, handle: id, avatar: AvatarSpec(), color: .lime), inbox: id + "-in", role: .member, joinedAt: joined)
    }

    func testGroupTrophies() {
        let cal = TestEnv.calendar
        let t = TestClock.date("2026-10-06T08:00:00+09:00")
        let members = ["_a", "_b", "_c"].map { member($0, joined: t.addingTimeInterval(-86400)) }
        // Same day, all three, within 10 minutes; plus a 4th member who joined *after* that day.
        var events = [ge("_a", t), ge("_b", t.addingTimeInterval(300)), ge("_c", t.addingTimeInterval(540))]
        let late = member("_d", joined: t.addingTimeInterval(3 * 86400))
        var status = Dictionary(uniqueKeysWithValues: GroupAchievementEngine.evaluate(events: events, members: members + [late], sessionParticipants: [], partyRSVPs: [], calendar: cal).map { ($0.id, $0) })
        XCTAssertTrue(status[.fullHouse]!.earned)
        XCTAssertTrue(status[.synchronized]!.earned)
        XCTAssertFalse(status[.nightShiftCrew]!.earned)
        XCTAssertFalse(status[.internationalIncident]!.earned)

        // Spread out over an hour: not synchronized. Two countries: international.
        events = [ge("_a", t, country: "JP"), ge("_b", t.addingTimeInterval(1800)), ge("_c", t.addingTimeInterval(3600), country: "MY")]
        status = Dictionary(uniqueKeysWithValues: GroupAchievementEngine.evaluate(events: events, members: members, sessionParticipants: [], partyRSVPs: [], calendar: cal).map { ($0.id, $0) })
        XCTAssertFalse(status[.synchronized]!.earned)
        XCTAssertTrue(status[.internationalIncident]!.earned)

        // Only two people: never a full house.
        status = Dictionary(uniqueKeysWithValues: GroupAchievementEngine.evaluate(events: [ge("_a", t), ge("_b", t)], members: Array(members.prefix(2)), sessionParticipants: [], partyRSVPs: [], calendar: cal).map { ($0.id, $0) })
        XCTAssertFalse(status[.fullHouse]!.earned)
    }

    func testTagTeamAndPartyOn() {
        let cal = TestEnv.calendar
        let t = TestClock.date("2026-10-06T08:00:00+09:00")
        let sid = UUID()
        func p(_ id: UserID, _ s: ParticipantStatus) -> PWMParticipant {
            PWMParticipant(sessionID: sid, person: PersonRef(id: id, handle: id, avatar: AvatarSpec(), color: .lime), status: s, startedAt: s == .invited ? nil : t)
        }
        let two = [p("_a", .joined), p("_b", .done), p("_c", .invited)]
        let three = [p("_a", .joined), p("_b", .done), p("_c", .joined)]
        let pid = UUID()
        func r(_ id: UserID, joined: Bool) -> PartyRSVP {
            PartyRSVP(partyID: pid, person: PersonRef(id: id, handle: id, avatar: AvatarSpec(), color: .lime), response: .yes, joinedAt: joined ? t : nil)
        }
        let s1 = GroupAchievementEngine.evaluate(events: [], members: [], sessionParticipants: [two], partyRSVPs: [[r("_a", joined: true), r("_b", joined: true), r("_c", joined: false)]], calendar: cal)
        XCTAssertFalse(s1.first { $0.id == .tagTeam }!.earned)
        XCTAssertFalse(s1.first { $0.id == .partyOn }!.earned)
        let s2 = GroupAchievementEngine.evaluate(events: [], members: [], sessionParticipants: [three], partyRSVPs: [[r("_a", joined: true), r("_b", joined: true), r("_c", joined: true)]], calendar: cal)
        XCTAssertTrue(s2.first { $0.id == .tagTeam }!.earned)
        XCTAssertTrue(s2.first { $0.id == .partyOn }!.earned)
    }

    func testFriendLeaderboardIncludesMe() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        store.logInstant()
        let board = store.friendLeaderboard()
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board.first?.person.id, "_me")
        XCTAssertEqual(board.first?.count, 1)
    }

    func testJoinFromNotificationNeverDoubleCounts() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        // JOIN tapped from a notification before the session synced: +1 now.
        let e = store.startTimed(pwmSessionID: sid)
        XCTAssertEqual(store.todayCount(), 1)
        clock.advance(120)
        store.finish()
        // Session arrives later: attach, don't create another poop.
        store.apply([.upsert(.pwmSession(PWMSession(id: sid, creatorID: "_josh")), zone: zone)])
        store.attachToPWM(zone: zone, sessionID: sid, eventID: e.id)
        XCTAssertEqual(store.todayCount(), 1)
        XCTAssertEqual(store.cache.zones[zone]?.participants[sid]?["_me"]?.status, .done)
        XCTAssertEqual(store.cache.zones[zone]?.participants[sid]?["_me"]?.eventID, e.id)
    }

    func testLabelsDisambiguateInsideOneZoneOnly() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let zone = ZoneRef(ownerName: "_josh", zoneName: ZoneNames.session(UUID()))
        let sid = UUID()
        let lee2 = PersonRef(id: "_other", handle: "lee", avatar: AvatarSpec(), color: .mint)
        store.apply([
            .upsert(.pwmSession(PWMSession(id: sid, creatorID: "_josh")), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: store.meRef, status: .invited)), zone: zone),
            .upsert(.participant(PWMParticipant(sessionID: sid, person: lee2, status: .joined, startedAt: clock.now)), zone: zone)
        ])
        let labels = store.labels(in: zone)
        XCTAssertEqual(Set([labels["_me"], labels["_other"]]), Set(["@lee (1)", "@lee (2)"]))
    }
}
