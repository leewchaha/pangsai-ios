import XCTest
@testable import ShittyFriends

final class LoggingTests: XCTestCase {
    func testSingleTapCountsImmediatelyAndGoesLive() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        XCTAssertEqual(store.todayCount(), 0)
        let e = store.startTimed()
        XCTAssertEqual(store.todayCount(), 1, "+1 must happen at session start")
        XCTAssertTrue(e.isLive)
        XCTAssertEqual(store.liveEvent?.id, e.id)
        XCTAssertTrue(log.saves.contains(.event(e.id)))
        XCTAssertTrue(log.pings.contains(.poop(eventID: e.id, kind: .poopStart)))
        XCTAssertTrue(log.contains(.scheduleLongSessionReminder(eventID: e.id, at: clock.now.addingTimeInterval(1800))))
    }

    func testSecondSingleTapDoesNotDoubleCount() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let a = store.startTimed()
        clock.advance(5)
        let b = store.startTimed()
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.todayCount(), 1)
    }

    func testDoubleTapInstantIsNotLive() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let e = store.logInstant()
        XCTAssertFalse(e.isLive)
        XCTAssertNil(store.liveEvent)
        XCTAssertNil(e.duration)
        XCTAssertTrue(log.pings.contains(.poop(eventID: e.id, kind: .poopInstant)))
    }

    func testDoneEndsTimerButKeepsPoop() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(462)
        store.finish()
        XCTAssertNil(store.liveEvent)
        XCTAssertEqual(store.my.events[e.id]?.duration ?? 0, 462, accuracy: 0.01)
        XCTAssertEqual(store.todayCount(), 1)
        XCTAssertTrue(log.contains(.cancelLongSessionReminder(eventID: e.id)))
        XCTAssertTrue(log.contains(.cancelPings(eventID: e.id)))
    }

    func testUndoWithinWindowDeletes() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let e = store.logInstant()
        clock.advance(3)
        store.performUndo()
        XCTAssertEqual(store.todayCount(), 0)
        XCTAssertTrue(log.deletes.contains(.event(e.id)))
        XCTAssertTrue(log.contains(.cancelPings(eventID: e.id)))
    }

    func testUndoAfterWindowDoesNothing() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        _ = store.logInstant()
        clock.advance(30)
        store.performUndo()
        XCTAssertEqual(store.todayCount(), 1)
    }

    func testManualLogNeverPingsOrGoesLive() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let e = store.addManual(at: clock.now.addingTimeInterval(-3600), duration: 300, location: nil)
        XCTAssertEqual(e.source, .manual)
        XCTAssertFalse(e.isLive)
        XCTAssertNil(store.liveEvent)
        XCTAssertEqual(e.duration ?? 0, 300, accuracy: 0.01)
        XCTAssertTrue(log.pings.isEmpty, "manual logs must not send 'is pooping' alerts")
    }

    func testForgottenTimerCanBeCorrected() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        clock.advance(5 * 3600)
        XCTAssertTrue(store.liveEvent!.isSuspicious(now: clock.now))
        store.edit(e.id, end: .some(e.startedAt.addingTimeInterval(420)))
        let fixed = store.my.events[e.id]!
        XCTAssertFalse(fixed.isLive)
        XCTAssertEqual(fixed.duration ?? 0, 420, accuracy: 0.01)
        XCTAssertTrue(fixed.manuallyAdjusted)
        XCTAssertEqual(store.todayCount(), 1, "never invalidate the poop")
    }

    func testEditEndBeforeStartClamps() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.startTimed()
        store.edit(e.id, end: .some(e.startedAt.addingTimeInterval(-100)))
        XCTAssertEqual(store.my.events[e.id]?.duration, 0)
    }

    func testLocationAttachAndClear() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let e = store.logInstant()
        store.attachLocation(PoopLocation(latitude: 36.7, longitude: 137.2, placeName: "Toyama Station"), to: e.id)
        XCTAssertEqual(store.my.events[e.id]?.location?.label, "Toyama Station")
        XCTAssertFalse(store.my.events[e.id]!.manuallyAdjusted)
        store.edit(e.id, location: .some(nil))
        XCTAssertNil(store.my.events[e.id]?.location)
    }

    func testRequestsLocationWhenDefaultOn() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        store.updateSettings { $0.attachLocationByDefault = true }
        let e = store.logInstant()
        XCTAssertTrue(log.contains(.requestLocation(eventID: e.id)))
    }

    func testGroupMirroring() {
        let clock = TestClock()
        let (store, log) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "The Boys", object: .toilet, color: .violet)!
        log.effects.removeAll()
        let e = store.logInstant()
        XCTAssertTrue(log.saves.contains(.groupEvent(link.zone, e.id)))
        XCTAssertNotNil(store.cache.zones[link.zone]?.events[e.id])
        store.attachLocation(PoopLocation(latitude: 1, longitude: 2), to: e.id)
        XCTAssertNil(store.cache.zones[link.zone]?.events[e.id]?.location, "locations stay out of groups by default")
        store.setGroupPrefs(link.id, shareLocations: true)
        XCTAssertNotNil(store.cache.zones[link.zone]?.events[e.id]?.location)
        store.delete(e.id)
        XCTAssertNil(store.cache.zones[link.zone]?.events[e.id])
        XCTAssertTrue(log.deletes.contains(.groupEvent(link.zone, e.id)))
    }

    func testUnsharedEventLeavesGroups() {
        let clock = TestClock()
        let (store, _) = TestEnv.store(clock: clock)
        let link = store.createGroupLocal(name: "Dorm", object: .roll, color: .aqua)!
        let e = store.logInstant()
        store.edit(e.id, sharedToGroups: false)
        XCTAssertNil(store.cache.zones[link.zone]?.events[e.id])
    }
}
