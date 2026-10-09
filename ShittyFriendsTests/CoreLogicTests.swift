import XCTest
@testable import ShittyFriends

final class CoreLogicTests: XCTestCase {
    // MARK: Records

    func testRecordNamesRoundTrip() {
        let g = ZoneRef(ownerName: "_owner", zoneName: ZoneNames.group(UUID()))
        let mine = ZoneRef(ownerName: ZoneRef.currentUser, zoneName: ZoneNames.session(UUID()))
        let refs: [RecordRef] = [
            .profile, .event(UUID()), .achievement(.sevenDay), .cosmetic(.gold),
            .settings, .friendLink(UUID()), .groupLink(UUID()), .invite("tok_123-abc"), .spaceLink(mine),
            .groupInfo(g), .member(g, "_abc123"), .groupEvent(g, UUID()), .pwmSession(g, UUID()),
            .participant(g, UUID(), "_xyz"), .reaction(mine, UUID()), .party(g, UUID()), .rsvp(g, UUID(), "_u1")
        ]
        for r in refs {
            XCTAssertEqual(RecordRef.parse(recordName: r.recordName, zone: r.zone), r, "\(r)")
            XCTAssertLessThan(r.recordName.count, 255)
        }
        XCTAssertNil(RecordRef.parse(recordName: "garbage", zone: .me))
    }

    func testZoneNames() {
        let id = UUID()
        XCTAssertEqual(ZoneNames.groupID(fromZoneName: ZoneNames.group(id)), id)
        XCTAssertNil(ZoneNames.groupID(fromZoneName: ZoneNames.session(id)))
    }

    // MARK: Deep links

    func testFriendInviteRoundTrip() {
        let p = FriendInvitePayload(handle: "lee", color: .lime, avatar: AvatarSpec(shape: .blob, tone: 3, eyes: .wink, mouth: .grin, accessory: .crown), token: "tok", userID: "_lee")
        let url = DeepLinkCodec.friendURL(p)
        XCTAssertEqual(url.scheme, "shittyfriends")
        guard case .friendInvite(let back)? = DeepLinkCodec.parse(url) else { return XCTFail() }
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.avatar.accessory, .crown)
        let text = DeepLinkCodec.friendShareText(handle: "lee", url: url)
        guard case .friendInvite(let found)? = DeepLinkCodec.find(in: "hey!! " + text + " see you") else { return XCTFail() }
        XCTAssertEqual(found, p)
    }

    func testGroupInviteRoundTrip() {
        let p = GroupInvitePayload(name: "The Boys", object: .crown, color: .violet, code: "abcDEF123")
        guard case .groupInvite(let back)? = DeepLinkCodec.parse(DeepLinkCodec.groupURL(p)) else { return XCTFail() }
        XCTAssertEqual(back.n, "The Boys")
        XCTAssertEqual(back.object, .crown)
        XCTAssertEqual(back.k, "abcDEF123")
        XCTAssertNil(DeepLinkCodec.parse(URL(string: "https://example.com/x")!))
        XCTAssertNil(DeepLinkCodec.parse(URL(string: "https://www.icloud.com/share/0abcDEF")!), "old iCloud share links are not invites any more")
    }

    func testOldFriendInviteLinksStillParse() throws {
        // v1 links (CloudKit era) carry no inviter id; the token resolves it on the server.
        let old = Data(#"{"v":1,"h":"lee","c":"lime","a":"round.0.dots.smile.none","t":"tok","k":"secret"}"#.utf8).base64URLEncodedString()
        guard case .friendInvite(let p)? = DeepLinkCodec.parse(URL(string: "shittyfriends://friend?d=\(old)")!) else { return XCTFail() }
        XCTAssertEqual(p.h, "lee")
        XCTAssertNil(p.u)
    }

    // MARK: Handles

    func testHandleValidation() {
        XCTAssertNil(HandleRules.validate("@Lee"))
        XCTAssertEqual(HandleRules.normalize("  @@Lee "), "lee")
        XCTAssertEqual(HandleRules.validate("a"), .tooShort)
        XCTAssertEqual(HandleRules.validate("lee!"), .invalidCharacters)
        XCTAssertEqual(HandleRules.validate(".lee"), .badDots)
        XCTAssertEqual(HandleRules.validate("le..e"), .badDots)
        XCTAssertEqual(HandleRules.validate(String(repeating: "x", count: 21)), .tooLong)
        XCTAssertEqual(HandleRules.validate("h1tler"), .notAllowed)
        XCTAssertNil(HandleRules.validate("grapefruit"))
        XCTAssertNil(ContentFilter.cleanGroupName("  "))
        XCTAssertEqual(ContentFilter.cleanGroupName(" The Boys "), "The Boys")
    }

    // MARK: Calendar

    func testMonthGridMondayFirst() {
        let cal = TestEnv.calendar
        let grid = CalendarMath.monthGrid(MonthKey(year: 2026, month: 10), calendar: cal)
        // Oct 1 2026 is a Thursday -> 3 leading blanks
        XCTAssertNil(grid[0]); XCTAssertNil(grid[2])
        XCTAssertEqual(grid[3], DayKey(year: 2026, month: 10, day: 1))
        XCTAssertEqual(grid.count % 7, 0)
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
    }

    func testStreaks() {
        let cal = TestEnv.calendar
        let today = DayKey(year: 2026, month: 10, day: 6)
        var days: Set<DayKey> = []
        for i in 1...5 { days.insert(today.adding(days: -i, calendar: cal)) }
        var s = CalendarMath.streaks(days: days, today: today, calendar: cal)
        XCTAssertEqual(s.current, 5, "streak alive until today ends")
        XCTAssertEqual(s.longest, 5)
        days.insert(today)
        days.insert(today.adding(days: -20, calendar: cal))
        s = CalendarMath.streaks(days: days, today: today, calendar: cal)
        XCTAssertEqual(s.current, 6)
        XCTAssertEqual(s.longest, 6)
        XCTAssertEqual(CalendarMath.streaks(days: [], today: today, calendar: cal).current, 0)
    }

    func testQuietHoursAcrossMidnight() {
        var s = AppSettings()
        s.quietHoursEnabled = true
        s.quietStartMinutes = 23 * 60
        s.quietEndMinutes = 7 * 60
        XCTAssertTrue(s.isQuiet(minutesFromMidnight: 23 * 60 + 30))
        XCTAssertTrue(s.isQuiet(minutesFromMidnight: 3 * 60))
        XCTAssertFalse(s.isQuiet(minutesFromMidnight: 12 * 60))
        s.quietHoursEnabled = false
        XCTAssertFalse(s.isQuiet(minutesFromMidnight: 3 * 60))
    }

    // MARK: Stats / achievements / highlights

    func testStatsAndPlaces() {
        let cal = TestEnv.calendar
        let base = TestClock.date("2026-10-06T08:00:00+09:00")
        let home = PoopLocation(latitude: 36.70, longitude: 137.21, placeName: "Home", locality: "Toyama", countryCode: "JP")
        let tpu = PoopLocation(latitude: 36.69, longitude: 137.10, placeName: "TPU", locality: "Imizu", countryCode: "JP")
        let events = [
            PoopEvent(source: .timed, startedAt: base, endedAt: base.addingTimeInterval(494), location: home),
            PoopEvent(source: .timed, startedAt: base.addingTimeInterval(5 * 3600), endedAt: base.addingTimeInterval(5 * 3600 + 291), location: tpu),
            PoopEvent(source: .manual, startedAt: base.addingTimeInterval(8 * 3600), location: home),
            PoopEvent(source: .timed, startedAt: base.addingTimeInterval(-86400), endedAt: base.addingTimeInterval(-86400 + 7200)) // forgotten timer
        ]
        let s = StatsCalculator.compute(events, now: base.addingTimeInterval(9 * 3600), calendar: cal)
        XCTAssertEqual(s.total, 4)
        XCTAssertEqual(s.activeDays, 2)
        XCTAssertEqual(s.longestSession ?? 0, 494, accuracy: 0.1, "suspicious durations excluded")
        XCTAssertEqual(s.shortestSession ?? 0, 291, accuracy: 0.1)
        XCTAssertEqual(s.uniquePlaces, 2)
        XCTAssertEqual(s.mostUsedPlace, "Home")
        XCTAssertEqual(s.cities, 2)
        XCTAssertEqual(s.currentStreak, 2)
    }

    func testAchievements() {
        let cal = TestEnv.calendar
        let now = TestClock.date("2026-10-30T12:00:00+09:00")
        var events: [PoopEvent] = []
        for d in 0..<7 {
            events.append(PoopEvent(source: .instant, startedAt: TestClock.date("2026-10-0\(d + 1)T08:1\(d % 3):00+09:00")))
        }
        events.append(PoopEvent(source: .instant, startedAt: TestClock.date("2026-10-10T02:00:00+09:00")))
        let ctx = AchievementContext(events: events, friendCount: 0, completedSocialSessions: 0, socialParties: 0, pastYesParties: [], ownedCosmetics: 1, now: now, calendar: cal)
        let ids = Set(AchievementEngine.newlyUnlocked(ctx, already: []).map { $0.id })
        XCTAssertTrue(ids.contains(.firstDrop))
        XCTAssertTrue(ids.contains(.sevenDay))
        XCTAssertTrue(ids.contains(.clockwork))
        XCTAssertTrue(ids.contains(.nightShift))
        XCTAssertFalse(ids.contains(.earlyBird))
        XCTAssertFalse(ids.contains(.monthlyRegular))
        XCTAssertFalse(ids.contains(.firstFriend))
        XCTAssertTrue(AchievementEngine.newlyUnlocked(ctx, already: Set(AchievementID.allCases)).isEmpty)
        XCTAssertEqual(AchievementEngine.progress(.monthlyRegular, ctx)?.current, 8)
    }

    func testNoAchievementRewardsFrequencyAlone() {
        // 20 logs in a single day must not unlock anything beyond First Drop / time-of-day ones.
        let cal = TestEnv.calendar
        let base = TestClock.date("2026-10-06T10:00:00+09:00")
        let events = (0..<20).map { PoopEvent(source: .instant, startedAt: base.addingTimeInterval(Double($0) * 600)) }
        let ctx = AchievementContext(events: events, friendCount: 0, completedSocialSessions: 0, socialParties: 0, pastYesParties: [], ownedCosmetics: 1, now: base.addingTimeInterval(86400), calendar: cal)
        let ids = Set(AchievementEngine.newlyUnlocked(ctx, already: []).map { $0.id })
        XCTAssertEqual(ids, [.firstDrop])
    }

    func testHighlights() {
        let cal = TestEnv.calendar
        let ref = TestClock.date("2026-10-08T12:00:00+09:00")
        let t = TestClock.date("2026-10-06T07:00:00+09:00")
        let lee = HighlightParticipant(id: "a", handle: "lee", color: .lime, events: [
            HighlightEvent(startedAt: t, endedAt: t.addingTimeInterval(300), source: .timed, location: nil),
            HighlightEvent(startedAt: t.addingTimeInterval(86400), endedAt: nil, source: .instant, location: nil)
        ])
        let sam = HighlightParticipant(id: "b", handle: "sam", color: .electric, events: [
            HighlightEvent(startedAt: t.addingTimeInterval(120), endedAt: nil, source: .instant, location: nil),
            HighlightEvent(startedAt: t.addingTimeInterval(86400 + 300), endedAt: nil, source: .instant, location: nil),
            HighlightEvent(startedAt: TestClock.date("2026-10-07T01:30:00+09:00"), endedAt: nil, source: .instant, location: nil)
        ])
        let cards = HighlightsEngine.cards(for: [lee, sam], period: .week, reference: ref, calendar: cal, isGroup: true)
        let byKind = Dictionary(uniqueKeysWithValues: cards.map { ($0.kind, $0) })
        XCTAssertEqual(byKind[.total]?.headline, "5")
        XCTAssertEqual(byKind[.throneOccupant]?.headline, "@sam")
        XCTAssertEqual(byKind[.poopBuddies]?.detail, "2 times within 10 min")
        XCTAssertEqual(byKind[.nightShift]?.headline, "@sam")
        XCTAssertEqual(byKind[.earlyBird]?.headline, "@lee")
        XCTAssertNotNil(byKind[.speedRun])
        XCTAssertTrue(HighlightsEngine.cards(for: [], period: .day, reference: ref, calendar: cal, isGroup: false).isEmpty)
    }

    // MARK: Notifications

    func testNotificationTextPrivacy() {
        let t = NotificationTextBuilder.text(kind: .poopStart, sender: "lee", groupName: nil, privateMode: false, quiet: false)
        XCTAssertEqual(t.title, "💩 @lee is pooping")
        let p = NotificationTextBuilder.text(kind: .poopStart, sender: "lee", groupName: nil, privateMode: true, quiet: true)
        XCTAssertEqual(p.title, "ShittyFriends")
        XCTAssertEqual(p.body, "@lee checked in")
        XCTAssertTrue(p.silent)
        let g = NotificationTextBuilder.text(kind: .pwmInvite, sender: "josh", groupName: "The Boys", privateMode: false, quiet: false)
        XCTAssertEqual(g.title, "💩 @josh wants to poop with you")
        XCTAssertEqual(g.body, "JOIN · The Boys")
        XCTAssertEqual(g.category, NotificationCategory.pwmInvite)
        let unknown = NotificationTextBuilder.text(kind: .poopInstant, sender: nil, groupName: nil, privateMode: false, quiet: false)
        XCTAssertEqual(unknown.title, "💩 A shitty friend just pooped")
        let party = NotificationTextBuilder.text(kind: .partyInvite, sender: "sam", groupName: "Dorm", partyTitle: "Friday Flush", privateMode: false, quiet: false)
        XCTAssertEqual(party.body, "Friday Flush · Dorm")
        let request = NotificationTextBuilder.text(kind: .groupJoinRequest, sender: "sam", groupName: "Dorm", privateMode: true, quiet: false)
        XCTAssertEqual(request.title, "ShittyFriends")
        XCTAssertFalse(request.body.contains("Dorm"), "private mode names no group")
    }

    func testDirectoryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.lockScreenPrivate = true
        settings.quietHoursEnabled = true
        let d = PingDirectory(settings: settings)
        try d.write(to: dir)
        let back = PingDirectory.read(from: dir)
        XCTAssertEqual(back?.lockScreenPrivate, true)
        XCTAssertEqual(back?.isQuiet(minutesFromMidnight: 3 * 60), true)
    }

    // MARK: Map

    func testMapClustering() {
        let now = Date()
        let pts = [
            MapPoint(id: "1", ownerID: "a", latitude: 36.700, longitude: 137.210, label: "Home", date: now),
            MapPoint(id: "2", ownerID: "a", latitude: 36.7001, longitude: 137.2101, label: "Home", date: now),
            MapPoint(id: "3", ownerID: "b", latitude: 35.0, longitude: 135.0, label: "Kyoto", date: now)
        ]
        let zoomedOut = MapClustering.cluster(pts, latitudeDelta: 5, longitudeDelta: 5)
        XCTAssertEqual(zoomedOut.count, 2)
        XCTAssertEqual(zoomedOut.map { $0.count }.sorted(), [1, 2])
        let zoomedIn = MapClustering.cluster(pts, latitudeDelta: 0.00001, longitudeDelta: 0.00001)
        XCTAssertEqual(zoomedIn.count, 3)
    }

    func testPreciseMapPinsStayOnActualPoopCoordinateAndIgnoreCameraZoom() throws {
        let now = Date()
        let older = MapPoint(id: "a", ownerID: "a", latitude: 36.7000, longitude: 137.2100,
                             label: "Older", date: now.addingTimeInterval(-90))
        let newest = MapPoint(id: "b", ownerID: "b", latitude: 36.70008, longitude: 137.21005,
                              label: "Latest", date: now)
        let elsewhere = MapPoint(id: "c", ownerID: "c", latitude: 36.7010, longitude: 137.2110,
                                 label: "Other site", date: now.addingTimeInterval(-60))
        let clusters = MapClustering.atRecordedLocations([older, elsewhere, newest])
        XCTAssertEqual(clusters.count, 2)
        let shared = try XCTUnwrap(clusters.first { $0.count == 2 })
        XCTAssertEqual(shared.latitude, newest.latitude) // not a visual centroid
        XCTAssertEqual(shared.longitude, newest.longitude)
        XCTAssertEqual(shared.ownerIDsByRecency, ["b", "a"])
        XCTAssertEqual(MapClustering.atRecordedLocations([older, newest], withinMeters: 1).count, 2)
    }

    func testMapClusterOwnersAreOrderedByMostRecentPoop() {
        let base = TestClock.date("2026-10-07T10:00:00+09:00")
        let cluster = MapCluster(id: "x", latitude: 0, longitude: 0, points: [
            MapPoint(id: "a-old", ownerID: "a", latitude: 0, longitude: 0, label: "A", date: base),
            MapPoint(id: "c", ownerID: "c", latitude: 0, longitude: 0, label: "C", date: base.addingTimeInterval(30)),
            MapPoint(id: "a-new", ownerID: "a", latitude: 0, longitude: 0, label: "A", date: base.addingTimeInterval(60)),
            MapPoint(id: "b", ownerID: "b", latitude: 0, longitude: 0, label: "B", date: base.addingTimeInterval(90))
        ])
        XCTAssertEqual(cluster.ownerIDsByRecency, ["b", "a", "c"])
    }

    func testHomeMapShowsEveryLocatedPoopGroupedBySpot() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let home = PoopLocation(latitude: 36.7000, longitude: 137.2100, placeName: "Home")
        let homeJitter = PoopLocation(latitude: 36.70005, longitude: 137.21004, placeName: "Home")
        let station = PoopLocation(latitude: 36.7010, longitude: 137.2130, placeName: "Station")
        let a = store.logInstant(); store.attachLocation(home, to: a.id)
        clock.advance(3600)
        let b = store.logInstant(); store.attachLocation(homeJitter, to: b.id)
        clock.advance(3600)
        let c = store.logInstant(); store.attachLocation(station, to: c.id)
        clock.advance(60)
        _ = store.logInstant() // no location: not on the map

        let points = store.mapPoints(includeMine: true, friendIDs: [], groupZones: [])
        XCTAssertEqual(points.count, 3, "history, not just the latest poop")
        let clusters = MapClustering.atRecordedLocations(points)
        XCTAssertEqual(clusters.count, 2)
        let homeCluster = clusters.first { $0.count == 2 }
        XCTAssertNotNil(homeCluster)
        XCTAssertEqual(homeCluster?.pointsByRecency.map(\.id), [b.id.uuidString, a.id.uuidString])
        XCTAssertEqual(homeCluster?.ownerIDsByRecency.count, 1)
    }

    func testPersonalHighlightsIgnoreFriends() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        store.logInstant()
        clock.advance(600)
        store.logInstant()
        let cards = store.myHighlightCards(period: .day)
        XCTAssertEqual(cards.first { $0.kind == .total }?.headline, "2")
        XCTAssertFalse(cards.contains { $0.kind == .throneOccupant || $0.kind == .poopBuddies }, "solo highlights never rank other people")
    }
}
